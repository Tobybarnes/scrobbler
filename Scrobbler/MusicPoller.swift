import Foundation
import Combine

class MusicPoller {
    let publisher = PassthroughSubject<TrackState?, Never>()
    var onError: ((Error?) -> Void)?

    private var timer: Timer?
    private let interval: TimeInterval
    private let scriptRunner: (String) throws -> String?

    // Production init — executes AppleScript to read Music
    convenience init(interval: TimeInterval = 5.0) {
        self.init(interval: interval) { script in
            var error: NSDictionary?
            guard let appleScript = NSAppleScript(source: script) else {
                throw NSError(domain: "Scrobbler.AppleScript", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "The Music script could not be created."
                ])
            }
            let result = appleScript.executeAndReturnError(&error)
            if let error {
                throw NSError(domain: "Scrobbler.AppleScript",
                              code: error[NSAppleScript.errorNumber] as? Int ?? -1,
                              userInfo: [NSLocalizedDescriptionKey:
                                error[NSAppleScript.errorMessage] as? String ?? "The Music script failed."])
            }
            return result.stringValue
        }
    }

    // Testable init — injectable script runner
    init(interval: TimeInterval = 5.0, scriptRunner: @escaping (String) throws -> String?) {
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
            do {
                let output = try self.scriptRunner(Self.appleScript)
                let state = output.flatMap { Self.parseOutput($0) }
                DispatchQueue.main.async {
                    self.onError?(nil)
                    self.publisher.send(state)
                }
            } catch {
                let scriptError = error as NSError
                let number = scriptError.userInfo[NSAppleScript.errorNumber] as? Int ?? scriptError.code
                let reportedError: PollingError = number == -1743
                    ? .automationPermissionDenied
                    : .scriptFailed(error.localizedDescription)
                DispatchQueue.main.async {
                    self.onError?(reportedError)
                    self.publisher.send(nil)
                }
            }
        }
    }

    // MARK: - Helpers

    private enum PollingError: LocalizedError {
        case automationPermissionDenied
        case scriptFailed(String)

        var errorDescription: String? {
            switch self {
            case .automationPermissionDenied:
                return "Allow Scrobbler to control Music in System Settings > Privacy & Security > Automation."
            case .scriptFailed(let message):
                return "Couldn't read Apple Music: \(message)"
            }
        }
    }

    private static func parseDouble(_ string: String) -> Double? {
        // AppleScript may return a comma decimal separator on non-English locales.
        // Normalise to a period before parsing.
        let normalised = string.replacingOccurrences(of: ",", with: ".")
        return Double(normalised)
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

        guard let duration = parseDouble(lines[3]),
              let position = parseDouble(lines[4]) else { return nil }

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
