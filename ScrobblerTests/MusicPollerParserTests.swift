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

    func testDeniedAutomationReportsRecoveryInstructionsOnMainThread() {
        let reported = expectation(description: "Automation denial is reported")
        let poller = MusicPoller(interval: 3600) { _ in
            throw NSError(domain: "NSAppleScriptError", code: -1743, userInfo: [
                NSAppleScript.errorNumber: -1743,
                NSLocalizedDescriptionKey: "Not authorized to send Apple events to Music."
            ])
        }
        defer { poller.stop(); poller.onError = nil }
        poller.onError = { error in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNotNil(error)
            XCTAssertTrue(error?.localizedDescription.contains("Privacy & Security > Automation") == true)
            XCTAssertTrue(error?.localizedDescription.contains("Music") == true)
            reported.fulfill()
        }

        poller.start()
        wait(for: [reported], timeout: 2)
    }

    func testSuccessfulPollClearsAnEarlierScriptError() {
        let failed = expectation(description: "First poll reports the script failure")
        let recovered = expectation(description: "Next successful poll clears the error")
        var attempt = 0
        let poller = MusicPoller(interval: 3600) { _ in
            attempt += 1
            if attempt == 1 {
                throw NSError(domain: "NSAppleScriptError", code: -600, userInfo: [
                    NSLocalizedDescriptionKey: "Application isn't running."
                ])
            }
            return "not_running"
        }
        defer { poller.stop(); poller.onError = nil }
        poller.onError = { error in
            XCTAssertTrue(Thread.isMainThread)
            poller.stop()
            if let error {
                XCTAssertTrue(error.localizedDescription.contains("Application isn't running."))
                failed.fulfill()
                poller.start()
            } else {
                recovered.fulfill()
            }
        }

        poller.start()
        wait(for: [failed, recovered], timeout: 2, enforceOrder: true)
    }
}
