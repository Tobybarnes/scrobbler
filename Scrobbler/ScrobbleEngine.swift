import Foundation

@MainActor
class ScrobbleEngine {
    var isScrobblingEnabled = true
    var now: () -> Date = { Date() }
    /// Called with the artist name each time a scrobble fires. Used by AppDelegate
    /// to update the recent scrobbles list in the menu.
    var onScrobble: ((String) -> Void)?

    private let client: LastFMClient
    private let sessionKey: String

    // Current track state
    private var currentIdentity: TrackIdentity?
    private var trackStartDate: Date?
    private var accumulatedSeconds: TimeInterval = 0
    private var lastUpdateDate: Date?
    private var lastPosition: TimeInterval?
    private var hasScrobbled = false

    init(client: LastFMClient, sessionKey: String) {
        self.client = client
        self.sessionKey = sessionKey
    }

    func update(_ state: TrackState?) async {
        guard let state else {
            // Music.app gone — suspend accumulation
            lastUpdateDate = nil
            lastPosition = nil
            return
        }

        switch state.playerState {
        case .stopped:
            lastUpdateDate = nil
            lastPosition = nil
            return

        case .paused:
            lastUpdateDate = nil
            lastPosition = state.position
            return

        case .playing:
            await handlePlayingState(state)
        }
    }

    private func handlePlayingState(_ state: TrackState) async {
        let identity = state.identity
        let currentDate = now()

        // Detect new track or repeat (position jumped backwards by >2s)
        let isNewTrack = identity != currentIdentity
        let isRepeat = !isNewTrack &&
            (lastPosition.map { state.position < $0 - 2 } ?? false)

        if isNewTrack || isRepeat {
            // Start fresh for this track
            currentIdentity = identity
            trackStartDate = currentDate
            accumulatedSeconds = 0
            hasScrobbled = false
            lastUpdateDate = currentDate
            lastPosition = state.position

            if isScrobblingEnabled {
                Task { [weak self] in
                    guard let self else { return }
                    try? await self.client.updateNowPlaying(
                        track: state.track,
                        artist: state.artist,
                        album: state.album,
                        duration: Int(state.duration),
                        sessionKey: self.sessionKey
                    )
                }
            }
            return
        }

        // Same track, playing — accumulate time since last update
        if let last = lastUpdateDate {
            accumulatedSeconds += currentDate.timeIntervalSince(last)
        }
        lastUpdateDate = currentDate
        lastPosition = state.position

        // Check scrobble threshold
        if !hasScrobbled && isScrobblingEnabled {
            let threshold = min(state.duration * 0.5, 240)
            if accumulatedSeconds >= 30 && accumulatedSeconds >= threshold,
               let startDate = trackStartDate {
                hasScrobbled = true
                onScrobble?(state.artist)   // notify AppDelegate for recent-scrobbles list
                Task { [weak self] in
                    guard let self else { return }
                    try? await self.client.scrobble(
                        track: state.track,
                        artist: state.artist,
                        album: state.album,
                        timestamp: startDate,
                        sessionKey: self.sessionKey
                    )
                }
            }
        }
    }

    func loveCurrentTrack(track: String, artist: String) {
        Task { [weak self] in
            guard let self else { return }
            try? await self.client.love(track: track, artist: artist, sessionKey: self.sessionKey)
        }
    }
}
