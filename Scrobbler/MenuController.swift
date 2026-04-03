import AppKit

// All state needed to render the menu
struct AppState {
    enum Auth {
        case notAuthenticated
        case pendingApproval(token: String)
        case authenticated
    }

    var auth: Auth = .notAuthenticated
    var currentTrack: TrackState? = nil
    var isScrobblingEnabled: Bool = true
    var hasAPIError: Bool = false
    var recentArtists: [(artist: String, count: Int)] = []
}

class MenuController {
    // Called by AppDelegate when menu items are tapped
    var onConnect: (() -> Void)?
    var onApproved: ((String) -> Void)?      // passes the pending token
    var onPauseResume: (() -> Void)?
    var onLove: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onQuit: (() -> Void)?

    private var state = AppState()

    func buildMenu(for state: AppState) -> NSMenu {
        self.state = state
        let menu = NSMenu()

        switch state.auth {
        case .notAuthenticated:
            menu.addItem(withTitle: "Not connected to Last.fm", action: nil, keyEquivalent: "")
                .isEnabled = false
            menu.addItem(NSMenuItem.separator())
            menu.addItem(makeItem("Connect to Last.fm", action: #selector(connectTapped), target: self))

        case .pendingApproval(let token):
            menu.addItem(withTitle: "Waiting for approval…", action: nil, keyEquivalent: "")
                .isEnabled = false
            menu.addItem(makeItem("I've approved it", action: #selector(approvedTapped(_:)), target: self)
                .also { $0.representedObject = token })

        case .authenticated:
            buildAuthenticatedMenu(menu)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem("Quit", action: #selector(quitTapped), target: self))
        return menu
    }

    private func buildAuthenticatedMenu(_ menu: NSMenu) {
        // Error banner
        if state.hasAPIError {
            let errItem = NSMenuItem(title: "⚠ Last.fm unreachable", action: nil, keyEquivalent: "")
            errItem.isEnabled = false
            menu.addItem(errItem)
            menu.addItem(NSMenuItem.separator())
        }

        // Now Playing section
        let nowPlayingHeader = NSMenuItem(title: "NOW PLAYING", action: nil, keyEquivalent: "")
        nowPlayingHeader.isEnabled = false
        nowPlayingHeader.attributedTitle = sectionHeader("NOW PLAYING")
        menu.addItem(nowPlayingHeader)

        if let track = state.currentTrack, track.playerState == .playing {
            let dot = state.isScrobblingEnabled ? "● " : ""
            let trackItem = NSMenuItem(title: "\(dot)\(track.track)", action: nil, keyEquivalent: "")
            trackItem.isEnabled = false
            menu.addItem(trackItem)

            let metaItem = NSMenuItem(title: "  \(track.artist) · \(track.album)", action: nil, keyEquivalent: "")
            metaItem.isEnabled = false
            menu.addItem(metaItem)
        } else {
            let nothingItem = NSMenuItem(title: "Not playing", action: nil, keyEquivalent: "")
            nothingItem.isEnabled = false
            menu.addItem(nothingItem)
        }

        // Recent Scrobbles section (hidden if empty)
        if !state.recentArtists.isEmpty {
            menu.addItem(NSMenuItem.separator())
            let recentHeader = NSMenuItem(title: "RECENT SCROBBLES", action: nil, keyEquivalent: "")
            recentHeader.isEnabled = false
            recentHeader.attributedTitle = sectionHeader("RECENT SCROBBLES")
            menu.addItem(recentHeader)

            for entry in state.recentArtists.prefix(5) {
                let item = NSMenuItem(title: "\(entry.artist)  ×\(entry.count)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        // Actions
        let loveItem = makeItem("♡ Love this track", action: #selector(loveTapped), target: self)
        loveItem.isEnabled = state.currentTrack?.playerState == .playing
        menu.addItem(loveItem)

        let pauseTitle = state.isScrobblingEnabled ? "⏸ Pause scrobbling" : "▶ Resume scrobbling"
        menu.addItem(makeItem(pauseTitle, action: #selector(pauseResumeTapped), target: self))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem("Disconnect from Last.fm", action: #selector(disconnectTapped), target: self))
    }

    // MARK: - Actions

    @objc private func connectTapped()           { onConnect?() }
    @objc private func approvedTapped(_ sender: NSMenuItem) {
        onApproved?(sender.representedObject as? String ?? "")
    }
    @objc private func pauseResumeTapped()       { onPauseResume?() }
    @objc private func loveTapped()              { onLove?() }
    @objc private func disconnectTapped()        { onDisconnect?() }
    @objc private func quitTapped()              { onQuit?() }

    // MARK: - Helpers

    private func makeItem(_ title: String, action: Selector, target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        return item
    }

    private func sectionHeader(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
    }
}

private extension NSMenuItem {
    func also(_ configure: (NSMenuItem) -> Void) -> NSMenuItem {
        configure(self)
        return self
    }
}
