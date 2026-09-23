import AppKit
import Combine

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Components

    private let sessionStore = SessionStore()
    private let credentialStore = CredentialStore()
    private let lastFMClient = LastFMClient(credentials: nil)
    private let updateService = UpdateService()
    private var scrobbleEngine: ScrobbleEngine?
    private let poller = MusicPoller()
    private let menuController = MenuController()

    // MARK: - Status item

    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()

    // MARK: - App state

    private var appState = AppState() {
        didSet { rebuildMenu() }
    }

    private var recentScrobbleCounts: [String: Int] = [:]  // artist → count

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        setupStatusItem()
        setupMenuCallbacks()
        checkAuthAndStart()
    }

    // MARK: - Main menu

    /// A menu bar (LSUIElement) app has no main menu by default, which means
    /// Cmd+X/C/V/A and Undo don't work in any text field. Install a minimal
    /// hidden menu so standard editing shortcuts reach the responder chain.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Scrobbler", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApplication.shared.mainMenu = mainMenu
    }

    /// Bring this background app to the front so a modal alert gets keyboard focus
    /// instead of appearing behind (or typing into) whatever app was active.
    private func runModalInFront(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.window.level = .floating
        return alert.runModal()
    }

    // MARK: - Status item setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "scrobbler.status"
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Scrobbler")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
        }
        updateStatusItemTitle()
        statusItem.menu = menuController.buildMenu(for: appState)
    }

    private func updateStatusItemTitle() {
        let title: String

        switch appState.auth {
        case .notAuthenticated, .pendingApproval:
            title = "♫ Not connected"

        case .authenticated:
            if let track = appState.currentTrack, track.playerState == .playing {
                let truncated = String(track.track.prefix(30))
                let ellipsis = track.track.count > 30 ? "…" : ""
                title = "♫ \(truncated)\(ellipsis) — \(track.artist)"
            } else {
                title = "♫ Not playing"
            }
        }

        statusItem.button?.attributedTitle = NSAttributedString(string: "")
        statusItem.button?.toolTip = title
        statusItem.button?.contentTintColor = nil
    }

    private func rebuildMenu() {
        updateStatusItemTitle()
        statusItem.menu = menuController.buildMenu(for: appState)
    }

    // MARK: - Auth

    private func checkAuthAndStart() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let credentials = CredentialStore().load()
            let sessionKey = SessionStore().load()

            DispatchQueue.main.async {
                guard let self else { return }
                self.lastFMClient.credentials = credentials
                if credentials != nil, let sessionKey {
                    self.appState.auth = .authenticated
                    self.startPolling(sessionKey: sessionKey)
                } else {
                    self.appState.auth = .notAuthenticated
                }
            }
        }
    }

    private func startPolling(sessionKey: String) {
        let engine = ScrobbleEngine(client: lastFMClient, sessionKey: sessionKey)
        engine.onScrobble = { [weak self] artist in
            self?.recordScrobble(artist: artist)
        }
        scrobbleEngine = engine

        poller.publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.appState.currentTrack = state
                    await self.scrobbleEngine?.update(state)
                }
            }
            .store(in: &cancellables)

        poller.start()
    }

    // MARK: - Menu callbacks

    private func setupMenuCallbacks() {
        menuController.onConnect = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.handleConnect()
            }
        }

        menuController.onConfigureCredentials = { [weak self] in
            self?.configureCredentials()
        }

        menuController.onCheckForUpdates = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.checkForUpdates()
            }
        }

        menuController.onApproved = { [weak self] token in
            Task { @MainActor [weak self] in
                await self?.handleApproved(token: token)
            }
        }

        menuController.onPauseResume = { [weak self] in
            guard let self else { return }
            self.appState.isScrobblingEnabled.toggle()
            self.scrobbleEngine?.isScrobblingEnabled = self.appState.isScrobblingEnabled
        }

        menuController.onLove = { [weak self] in
            guard let self,
                  let track = self.appState.currentTrack,
                  track.playerState == .playing else { return }
            self.scrobbleEngine?.loveCurrentTrack(track: track.track, artist: track.artist)
        }

        menuController.onDisconnect = { [weak self] in
            self?.handleDisconnect()
        }

        menuController.onQuit = {
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Auth flow

    private func handleConnect() async {
        guard lastFMClient.credentials != nil || configureCredentials() else { return }
        do {
            let token = try await lastFMClient.getToken()
            appState.auth = .pendingApproval(token: token)
            let urlString = "https://www.last.fm/api/auth/?api_key=\(lastFMClient.credentials!.apiKey)&token=\(token)"
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        } catch {
            showAlert("Couldn't connect to Last.fm", message: error.localizedDescription)
        }
    }

    private func handleApproved(token: String) async {
        do {
            let sessionKey = try await lastFMClient.getSession(token: token)
            try sessionStore.save(sessionKey)
            appState.auth = .authenticated
            appState.hasAPIError = false
            startPolling(sessionKey: sessionKey)
        } catch LastFMError.apiError(14, _) {
            showAlert(
                "Not approved yet",
                message: "It looks like you haven't approved access yet. Try again after approving on Last.fm."
            )
            // Keep .pendingApproval state so user can try again without restarting flow
        } catch LastFMError.apiError(15, _) {
            showAlert(
                "Authorisation expired",
                message: "The authorisation expired. Please try connecting again."
            )
            appState.auth = .notAuthenticated
        } catch {
            showAlert("Authorisation failed", message: error.localizedDescription)
            appState.auth = .notAuthenticated
        }
    }

    private func handleDisconnect() {
        poller.stop()
        cancellables.removeAll()
        scrobbleEngine = nil
        try? sessionStore.delete()
        appState = AppState()   // reset to defaults
        appState.auth = .notAuthenticated
    }

    // MARK: - Scrobble tracking (for recent artists list)

    func recordScrobble(artist: String) {
        recentScrobbleCounts[artist, default: 0] += 1
        appState.recentArtists = recentScrobbleCounts
            .sorted { $0.value > $1.value }
            .map { (artist: $0.key, count: $0.value) }
    }

    // MARK: - Helpers

    private func showAlert(_ title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        _ = runModalInFront(alert)
    }

    private func checkForUpdates() async {
        do {
            guard let release = try await updateService.checkForUpdate() else {
                showAlert("You’re up to date", message: "Scrobbler \(updateService.currentVersion) is the latest available version.")
                return
            }

            let confirmation = NSAlert()
            confirmation.messageText = "Scrobbler update available"
            confirmation.informativeText = "Install \(release.name) from GitHub? The app will restart when the update is installed."
            confirmation.addButton(withTitle: "Install Update")
            confirmation.addButton(withTitle: "Later")
            guard runModalInFront(confirmation) == .alertFirstButtonReturn else { return }

            try await updateService.install(release)
            NSWorkspace.shared.open(Bundle.main.bundleURL)
            NSApplication.shared.terminate(nil)
        } catch {
            showAlert("Update failed", message: error.localizedDescription)
        }
    }

    @discardableResult
    private func configureCredentials() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Last.fm credentials"
        alert.informativeText = "Enter your Last.fm API key and shared secret. They are stored only in this Mac’s Keychain."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let apiKeyLabel = NSTextField(labelWithString: "API key")
        let apiKeyField = NSTextField(string: lastFMClient.credentials?.apiKey ?? "")
        apiKeyField.placeholderString = "Last.fm API key"
        apiKeyField.translatesAutoresizingMaskIntoConstraints = false

        let secretLabel = NSTextField(labelWithString: "Shared secret")
        let secretField = NSSecureTextField(string: lastFMClient.credentials?.sharedSecret ?? "")
        secretField.placeholderString = "Last.fm shared secret"
        secretField.translatesAutoresizingMaskIntoConstraints = false

        let fields = NSStackView(views: [apiKeyLabel, apiKeyField, secretLabel, secretField])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 6
        NSLayoutConstraint.activate([
            apiKeyField.widthAnchor.constraint(equalToConstant: 320),
            secretField.widthAnchor.constraint(equalToConstant: 320)
        ])
        // NSAlert sizes its accessory view from the view's frame, not Auto Layout.
        // Without an explicit frame the stack collapses to zero and the fields draw
        // on top of each other, so give it its fitted size.
        fields.layoutSubtreeIfNeeded()
        fields.frame = NSRect(origin: .zero, size: fields.fittingSize)
        alert.accessoryView = fields
        alert.layout()
        alert.window.initialFirstResponder = apiKeyField
        apiKeyField.nextKeyView = secretField

        guard runModalInFront(alert) == .alertFirstButtonReturn else { return false }
        do {
            let credentials = LastFMCredentials(apiKey: apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                                sharedSecret: secretField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
            try credentialStore.save(credentials)
            lastFMClient.credentials = credentials
            return true
        } catch {
            showAlert("Couldn’t save credentials", message: error.localizedDescription)
            return false
        }
    }
}
