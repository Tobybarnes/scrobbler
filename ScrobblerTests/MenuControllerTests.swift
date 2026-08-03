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
