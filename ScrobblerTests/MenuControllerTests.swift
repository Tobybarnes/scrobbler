import AppKit
import XCTest
@testable import Scrobbler

final class MenuControllerTests: XCTestCase {
    func testMusicFailureShowsRecoveryActionInsteadOfNotPlaying() throws {
        var state = AppState()
        state.auth = .authenticated
        state.musicError = "Allow Scrobbler to control Music in System Settings > Privacy & Security > Automation."
        let controller = MenuController()
        var openedSettings = false
        controller.onOpenAutomationSettings = { openedSettings = true }

        let menu = controller.buildMenu(for: state)
        let errorItem = try XCTUnwrap(menu.items.first { $0.toolTip == state.musicError })
        let settingsItem = try XCTUnwrap(menu.items.first { $0.title == "Open Automation Settings…" })
        XCTAssertFalse(errorItem.isEnabled)
        XCTAssertFalse(menu.items.contains { $0.title == "Not playing" })
        XCTAssertTrue(settingsItem.isEnabled)
        let action = try XCTUnwrap(settingsItem.action)
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: settingsItem.target, from: settingsItem))
        XCTAssertTrue(openedSettings)
    }

    func testMusicRecoveryRemovesErrorAndSettingsAction() {
        let controller = MenuController()
        var state = AppState()
        state.auth = .authenticated
        state.musicError = "Music access was denied."
        _ = controller.buildMenu(for: state)

        state.musicError = nil
        let recoveredMenu = controller.buildMenu(for: state)
        XCTAssertTrue(recoveredMenu.items.contains { $0.title == "Not playing" })
        XCTAssertFalse(recoveredMenu.items.contains { $0.title == "Open Automation Settings…" })
    }

    func testLastFMErrorDescribesARequestFailureAndPreservesDetails() throws {
        var state = AppState()
        state.auth = .authenticated
        state.apiErrorMessage = "Invalid session key. Please re-authenticate."

        let menu = MenuController().buildMenu(for: state)
        let errorItem = try XCTUnwrap(menu.items.first { $0.title.contains("Last.fm request failed") })
        XCTAssertEqual(errorItem.toolTip, state.apiErrorMessage)
        XCTAssertFalse(errorItem.isEnabled)
        XCTAssertFalse(menu.items.contains { $0.title.contains("unreachable") })
    }

    func testNowPlayingRowsUseActiveMenuAppearance() throws {
        var state = AppState()
        state.auth = .authenticated
        state.currentTrack = TrackState(
            track: "Elephant",
            artist: "Tame Impala",
            album: "Lonerism",
            duration: 212,
            position: 45,
            playerState: .playing
        )

        let menu = MenuController().buildMenu(for: state)
        let trackItem = try XCTUnwrap(menu.items.first { $0.title.contains("Elephant") })
        let artistItem = try XCTUnwrap(menu.items.first { $0.title.contains("Tame Impala") })
        let trackIndex = try XCTUnwrap(menu.items.firstIndex(of: trackItem))
        let artistIndex = try XCTUnwrap(menu.items.firstIndex(of: artistItem))
        let trackTitle = try XCTUnwrap(trackItem.attributedTitle)
        let artistTitle = try XCTUnwrap(artistItem.attributedTitle)
        let trackFont = try XCTUnwrap(trackTitle.attribute(
            .font,
            at: 0,
            effectiveRange: nil
        ) as? NSFont)
        let artistFont = try XCTUnwrap(artistTitle.attribute(
            .font,
            at: 0,
            effectiveRange: nil
        ) as? NSFont)

        XCTAssertTrue(trackItem.isEnabled, "The current track should use the same dark active appearance as menu actions")
        XCTAssertTrue(artistItem.isEnabled, "The current track artist should use the same dark active appearance as menu actions")
        XCTAssertFalse(menu.autoenablesItems, "AppKit should not turn display-only track rows grey again")
        XCTAssertLessThan(artistIndex, trackIndex)
        XCTAssertEqual(artistItem.title, "Tame Impala")
        XCTAssertEqual(trackItem.title, "● Elephant")
        XCTAssertFalse(artistItem.title.contains("Lonerism"))
        XCTAssertTrue(trackFont.fontDescriptor.symbolicTraits.contains(NSFontDescriptor.SymbolicTraits.bold))
        XCTAssertEqual(artistFont.fontDescriptor.symbolicTraits, trackFont.fontDescriptor.symbolicTraits)
    }
}
