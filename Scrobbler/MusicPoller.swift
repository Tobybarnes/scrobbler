import Foundation
import Combine

class MusicPoller {
    let publisher = PassthroughSubject<TrackState?, Never>()

    private var timer: Timer?
    private let interval: TimeInterval
    private let scriptRunner: (String) -> String?

    // Production init — uses real osascript
    convenience init(interval: TimeInterval = 5.0) {
        self.init(interval: interval) { script in
            var error: NSDictionary?
            let appleScript = NSAppleScript(source: script)
            let result = appleScript?.executeAndReturnError(&error)
            if error != nil { return nil }
            return result?.stringValue
        }
    }

    // Testable init — injectable script runner
    init(interval: TimeInterval = 5.0, scriptRunner: @escaping (String) -> String?) {
        self.interval = interval
        self.scriptRunner = scriptRunner
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer?.fire()   // poll immediately on start
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let output = self.scriptRunner(Self.appleScript)
            let state = output.flatMap { Self.parseOutput($0) }
            DispatchQueue.main.async {
                self.publisher.send(state)
            }
        }
    }

    // MARK: - AppleScript

    private static let appleScript = """
    if application "Music" is running then
        tell application "Music"
            set pState to player state
            if pState is playing or pState is paused then
                set stateStr to "playing"
                if pState is paused then set stateStr to "paused"
                set t to name of current track
                set ar to artist of current track
                set al to album of current track
                set dur to duration of current track
                set pos to player position
                return t & "\\n" & ar & "\\n" & al & "\\n" & dur & "\\n" & pos & "\\n" & stateStr
            else
                return "\\n\\n\\n0\\n0\\nstopped"
            end if
        end tell
    else
        return "not_running"
    end if
    """

    // MARK: - Parser (static for testability)

    static func parseOutput(_ output: String) -> TrackState? {
        guard !output.isEmpty else { return nil }
        if output == "not_running" { return nil }

        let lines = output.components(separatedBy: "\n")
        guard lines.count == 6 else { return nil }

        let playerState: PlayerState
        switch lines[5] {
        case "playing": playerState = .playing
        case "paused":  playerState = .paused
        case "stopped": playerState = .stopped
        default:        return nil
        }

        // For stopped state, track fields are empty — return a minimal TrackState
        if playerState == .stopped {
            return TrackState(track: "", artist: "", album: "",
                              duration: 0, position: 0, playerState: .stopped)
        }

        guard let duration = Double(lines[3]),
              let position = Double(lines[4]) else { return nil }

        return TrackState(
            track: lines[0],
            artist: lines[1],
            album: lines[2],
            duration: duration,
            position: position,
            playerState: playerState
        )
    }
}
