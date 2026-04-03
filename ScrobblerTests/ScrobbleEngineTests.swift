import XCTest
@testable import Scrobbler

// Tracks API calls made during tests — no network
// Must be @MainActor because ScrobbleEngine is @MainActor
@MainActor
class MockLastFMClient: LastFMClient {
    var updateNowPlayingCalls: [(track: String, artist: String)] = []
    var scrobbleCalls: [(track: String, artist: String)] = []
    var loveCalls: [(track: String, artist: String)] = []

    override func updateNowPlaying(track: String, artist: String, album: String,
                                   duration: Int, sessionKey: String) async throws {
        updateNowPlayingCalls.append((track, artist))
    }

    override func scrobble(track: String, artist: String, album: String,
                           timestamp: Date, sessionKey: String) async throws {
        scrobbleCalls.append((track, artist))
    }

    override func love(track: String, artist: String, sessionKey: String) async throws {
        loveCalls.append((track, artist))
    }
}

// @MainActor required: ScrobbleEngine is @MainActor-isolated and setUp/tests
// must run on the same actor to assign properties and call methods directly.
@MainActor
class ScrobbleEngineTests: XCTestCase {
    var mockClient: MockLastFMClient!
    var engine: ScrobbleEngine!

    // Controllable clock
    var fakeNow: Date = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        mockClient = MockLastFMClient()
        engine = ScrobbleEngine(client: mockClient, sessionKey: "test-sk")
        engine.now = { [weak self] in self?.fakeNow ?? Date() }
    }

    // MARK: updateNowPlaying

    func test_new_track_fires_updateNowPlaying() async {
        let state = makePlaying(track: "Elephant", position: 0)
        await engine.update(state)
        await Task.yield()
        XCTAssertEqual(mockClient.updateNowPlayingCalls.count, 1)
        XCTAssertEqual(mockClient.updateNowPlayingCalls[0].track, "Elephant")
    }

    func test_same_track_does_not_repeat_updateNowPlaying() async {
        let state = makePlaying(track: "Elephant", position: 0)
        await engine.update(state)
        await Task.yield()
        fakeNow = fakeNow.addingTimeInterval(5)
        await engine.update(makePlaying(track: "Elephant", position: 5))
        await Task.yield()
        XCTAssertEqual(mockClient.updateNowPlayingCalls.count, 1)
    }

    // MARK: scrobble threshold

    func test_no_scrobble_before_30_seconds() async {
        await engine.update(makePlaying(track: "Elephant", position: 0, duration: 212))
        advanceTime(by: 25)
        await engine.update(makePlaying(track: "Elephant", position: 25, duration: 212))
        await Task.yield()
        XCTAssertEqual(mockClient.scrobbleCalls.count, 0)
    }

    func test_scrobble_fires_after_threshold_met() async {
        // duration 60s → threshold = min(30s, 60s*0.5=30s) = 30s
        await engine.update(makePlaying(track: "Short Track", position: 0, duration: 60))
        advanceTime(by: 30)
        await engine.update(makePlaying(track: "Short Track", position: 30, duration: 60))
        await Task.yield()
        XCTAssertEqual(mockClient.scrobbleCalls.count, 1)
        XCTAssertEqual(mockClient.scrobbleCalls[0].track, "Short Track")
    }

    func test_scrobble_fires_only_once_per_play() async {
        await engine.update(makePlaying(track: "Short Track", position: 0, duration: 60))
        advanceTime(by: 31)
        await engine.update(makePlaying(track: "Short Track", position: 31, duration: 60))
        await Task.yield()
        advanceTime(by: 5)
        await engine.update(makePlaying(track: "Short Track", position: 36, duration: 60))
        await Task.yield()
        XCTAssertEqual(mockClient.scrobbleCalls.count, 1)
    }

    func test_long_track_scrobbles_at_4_minutes() async {
        // duration 20 min → 50% = 10 min, capped at 4 min
        let duration: TimeInterval = 20 * 60
        await engine.update(makePlaying(track: "Long Track", position: 0, duration: duration))
        advanceTime(by: 240) // 4 minutes
        await engine.update(makePlaying(track: "Long Track", position: 240, duration: duration))
        await Task.yield()
        XCTAssertEqual(mockClient.scrobbleCalls.count, 1)
    }

    // MARK: Pause handling

    func test_paused_time_not_accumulated() async {
        // 20s playing, then 20s paused, then 5s playing = 25s total played, not enough to scrobble
        await engine.update(makePlaying(track: "Elephant", position: 0, duration: 212))
        advanceTime(by: 20)
        await engine.update(makePlaying(track: "Elephant", position: 20, duration: 212))
        advanceTime(by: 20)
        await engine.update(makePaused(track: "Elephant", position: 20, duration: 212))
        advanceTime(by: 5)
        await engine.update(makePlaying(track: "Elephant", position: 25, duration: 212))
        await Task.yield()
        XCTAssertEqual(mockClient.scrobbleCalls.count, 0)
    }

    // MARK: Track change

    func test_track_change_resets_and_fires_updateNowPlaying_for_new_track() async {
        await engine.update(makePlaying(track: "Track A", position: 0, duration: 60))
        await Task.yield()
        advanceTime(by: 5)
        await engine.update(makePlaying(track: "Track B", position: 0, duration: 60))
        await Task.yield()
        XCTAssertEqual(mockClient.updateNowPlayingCalls.count, 2)
        XCTAssertEqual(mockClient.updateNowPlayingCalls[1].track, "Track B")
    }

    func test_track_change_before_threshold_does_not_scrobble_old_track() async {
        await engine.update(makePlaying(track: "Track A", position: 0, duration: 60))
        advanceTime(by: 10)
        await engine.update(makePlaying(track: "Track B", position: 0, duration: 60))
        await Task.yield()
        XCTAssertEqual(mockClient.scrobbleCalls.count, 0)
    }

    // MARK: Repeat detection

    func test_position_decrease_triggers_new_play() async {
        await engine.update(makePlaying(track: "Elephant", position: 30, duration: 212))
        await Task.yield()
        // Position jumped back — same track on repeat
        await engine.update(makePlaying(track: "Elephant", position: 5, duration: 212))
        await Task.yield()
        XCTAssertEqual(mockClient.updateNowPlayingCalls.count, 2)
    }

    // MARK: Nil state (Music.app quit)

    func test_nil_state_suspends_accumulation() async {
        await engine.update(makePlaying(track: "Elephant", position: 0, duration: 60))
        advanceTime(by: 20)
        await engine.update(nil)  // Music.app quit
        advanceTime(by: 20)
        await engine.update(makePlaying(track: "Elephant", position: 20, duration: 60))
        await Task.yield()
        // Should have accumulated ~20s, not 40s
        XCTAssertEqual(mockClient.scrobbleCalls.count, 0)
    }

    // MARK: Scrobbling disabled

    func test_scrobbling_disabled_suppresses_all_api_calls() async {
        engine.isScrobblingEnabled = false
        await engine.update(makePlaying(track: "Elephant", position: 0, duration: 60))
        advanceTime(by: 35)
        await engine.update(makePlaying(track: "Elephant", position: 35, duration: 60))
        await Task.yield()
        XCTAssertEqual(mockClient.updateNowPlayingCalls.count, 0)
        XCTAssertEqual(mockClient.scrobbleCalls.count, 0)
    }

    // MARK: Helpers

    private func makePlaying(track: String, position: TimeInterval, duration: TimeInterval = 212) -> TrackState {
        TrackState(track: track, artist: "Artist", album: "Album",
                   duration: duration, position: position, playerState: .playing)
    }

    private func makePaused(track: String, position: TimeInterval, duration: TimeInterval = 212) -> TrackState {
        TrackState(track: track, artist: "Artist", album: "Album",
                   duration: duration, position: position, playerState: .paused)
    }

    private func advanceTime(by seconds: TimeInterval) {
        fakeNow = fakeNow.addingTimeInterval(seconds)
    }
}
