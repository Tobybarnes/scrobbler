import XCTest
@testable import Scrobbler

class MusicPollerParserTests: XCTestCase {

    func test_parse_playing_state() {
        let output = "Elephant\nTame Impala\nLonerism\n212.5\n45.3\nplaying"
        let state = MusicPoller.parseOutput(output)
        XCTAssertNotNil(state)
        XCTAssertEqual(state?.track, "Elephant")
        XCTAssertEqual(state?.artist, "Tame Impala")
        XCTAssertEqual(state?.album, "Lonerism")
        XCTAssertEqual(state?.duration, 212.5)
        XCTAssertEqual(state?.position, 45.3)
        XCTAssertEqual(state?.playerState, .playing)
    }

    func test_parse_paused_state() {
        let output = "Elephant\nTame Impala\nLonerism\n212.5\n45.3\npaused"
        let state = MusicPoller.parseOutput(output)
        XCTAssertEqual(state?.playerState, .paused)
    }

    func test_parse_stopped_state_returns_stopped_trackstate() {
        let output = "\n\n\n0\n0\nstopped"
        let state = MusicPoller.parseOutput(output)
        XCTAssertNotNil(state)
        XCTAssertEqual(state?.playerState, .stopped)
    }

    func test_parse_unavailable_returns_nil() {
        let output = "not_running"
        let state = MusicPoller.parseOutput(output)
        XCTAssertNil(state)
    }

    func test_parse_empty_string_returns_nil() {
        XCTAssertNil(MusicPoller.parseOutput(""))
    }

    func test_parse_malformed_output_returns_nil() {
        XCTAssertNil(MusicPoller.parseOutput("something\nwrong"))
    }
}
