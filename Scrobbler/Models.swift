import Foundation

enum PlayerState: Equatable {
    case playing
    case paused
    case stopped
}

struct TrackState: Equatable {
    let track: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let position: TimeInterval
    let playerState: PlayerState
}

struct TrackIdentity: Equatable, Hashable {
    let track: String
    let artist: String
}

extension TrackState {
    var identity: TrackIdentity {
        TrackIdentity(track: track, artist: artist)
    }
}
