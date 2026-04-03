import XCTest
@testable import Scrobbler

class ModelsTests: XCTestCase {

    func test_playerState_cases_exist() {
        let _ = PlayerState.playing
        let _ = PlayerState.paused
        let _ = PlayerState.stopped
    }

    func test_trackState_stores_all_fields() {
        let state = TrackState(
            track: "Elephant",
            artist: "Tame Impala",
            album: "Lonerism",
            duration: 212.0,
            position: 45.0,
            playerState: .playing
        )
        XCTAssertEqual(state.track, "Elephant")
        XCTAssertEqual(state.artist, "Tame Impala")
        XCTAssertEqual(state.album, "Lonerism")
        XCTAssertEqual(state.duration, 212.0)
        XCTAssertEqual(state.position, 45.0)
        XCTAssertEqual(state.playerState, .playing)
    }

    func test_trackIdentity_equality() {
        let a = TrackIdentity(track: "Elephant", artist: "Tame Impala")
        let b = TrackIdentity(track: "Elephant", artist: "Tame Impala")
        let c = TrackIdentity(track: "Let It Happen", artist: "Tame Impala")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
