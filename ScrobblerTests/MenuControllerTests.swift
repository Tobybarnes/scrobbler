import AppKit
import XCTest
@testable import Scrobbler

final class MenuControllerTests: XCTestCase {
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
        let metadataItem = try XCTUnwrap(menu.items.first { $0.title.contains("Tame Impala") })
        let trackTitle = try XCTUnwrap(trackItem.attributedTitle)
        let trackFont = try XCTUnwrap(trackTitle.attribute(
            .font,
            at: 0,
            effectiveRange: nil
        ) as? NSFont)

        XCTAssertTrue(trackItem.isEnabled, "The current track should use the same dark active appearance as menu actions")
        XCTAssertTrue(metadataItem.isEnabled, "The current track metadata should use the same dark active appearance as menu actions")
        XCTAssertFalse(menu.autoenablesItems, "AppKit should not turn display-only track rows grey again")
        XCTAssertTrue(trackFont.fontDescriptor.symbolicTraits.contains(NSFontDescriptor.SymbolicTraits.bold))
    }
}
