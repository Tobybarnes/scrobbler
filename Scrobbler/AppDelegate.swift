import AppKit
import Combine

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Components

    private let sessionStore = SessionStore()
    private let lastFMClient = LastFMClient()
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
        setupStatusItem()
        setupMenuCallbacks()
        checkAuthAndStart()
    }

    // MARK: - Status item setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusItemTitle()
        statusItem.menu = menuController.buildMenu(for: appState)
    }

    private func updateStatusItemTitle() {
        let title: String
        let dotColor: NSColor?

        switch appState.auth {
        case .notAuthenticated, .pendingApproval:
            title = "♫ Not connected"
            dotColor = .systemOrange

        case .authenticated:
            if let track = appState.currentTrack, track.playerState == .playing {
                let truncated = String(track.track.prefix(30))
                let ellipsis = track.track.count > 30 ? "…" : ""
                title = "♫ \(truncated)\(ellipsis) — \(track.artist)"
            } else {
                title = "♫ Not playing"
            }
            if appState.hasAPIError {
                dotColor = .systemOrange
            } else if !appState.isScrobblingEnabled {
                dotColor = .secondaryLabelColor
            } else if appState.currentTrack?.playerState == .playing {
                dotColor = .systemRed
            } else {
                dotColor = nil
            }
        }

        let attributed = NSMutableAttributedString(string: title)
        if let color = dotColor {
            let dot = NSAttributedString(string: " ●", attributes: [.foregroundColor: color])
            attributed.append(dot)
        }
        statusItem.button?.attributedTitle = attributed
    }

    private func rebuildMenu() {
        updateStatusItemTitle()
        statusItem.menu = menuController.buildMenu(for: appState)
    }

    // MARK: - Auth

    private func checkAuthAndStart() {
        if let key = sessionStore.load() {
            appState.auth = .authenticated
            startPolling(sessionKey: key)
        } else {
            appState.auth = .notAuthenticated
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
        do {
            let token = try await lastFMClient.getToken()
            appState.auth = .pendingApproval(token: token)
            let urlString = "https://www.last.fm/api/auth/?api_key=\(LastFMClient.apiKey)&token=\(token)"
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
        alert.runModal()
    }
}
