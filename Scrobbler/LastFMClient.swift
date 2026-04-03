import Foundation
import CryptoKit

// MARK: - MD5 helper

extension String {
    var md5Hash: String {
        Insecure.MD5.hash(data: Data(utf8))
            .map { String(format: "%02hhx", $0) }
            .joined()
    }
}

// MARK: - Error model

enum LastFMError: Error, LocalizedError {
    case network(Error)
    case httpError(Int)
    case apiError(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .network(let e): return "Network error: \(e.localizedDescription)"
        case .httpError(let code): return "HTTP error \(code)"
        case .apiError(let code, let msg): return "Last.fm error \(code): \(msg)"
        case .invalidResponse: return "Invalid response from Last.fm"
        }
    }
}

// MARK: - URLSession protocol (declared here so it's available for tests)

protocol URLSessionProtocol {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessionProtocol {}

// MARK: - LastFMClient

class LastFMClient {
    static let apiKey = "c921ad1bc9f787ba5cc78fe927316420"
    static let secret = "48be52a4d433f832cf9b10ae0e0e501e"
    static let baseURL = URL(string: "https://ws.audioscrobbler.com/2.0/")!

    let session: URLSessionProtocol

    init(session: URLSessionProtocol = URLSession.shared) {
        self.session = session
    }

    // Signing: sort params alphabetically (excluding "format"), concatenate key+value, append secret, MD5
    static func apiSignature(params: [String: String], secret: String) -> String {
        params
            .filter { $0.key != "format" }
            .sorted { $0.key < $1.key }
            .map { $0.key + $0.value }
            .joined()
            .appending(secret)
            .md5Hash
    }

    // MARK: - Track methods (in class body so they can be overridden in test mocks)

    func updateNowPlaying(track: String, artist: String, album: String,
                          duration: Int, sessionKey: String) async throws {
        _ = try await post(params: [
            "method": "track.updateNowPlaying",
            "api_key": Self.apiKey,
            "sk": sessionKey,
            "track": track,
            "artist": artist,
            "album": album,
            "duration": String(duration)
        ])
    }

    func scrobble(track: String, artist: String, album: String,
                  timestamp: Date, sessionKey: String) async throws {
        _ = try await post(params: [
            "method": "track.scrobble",
            "api_key": Self.apiKey,
            "sk": sessionKey,
            "track[0]": track,
            "artist[0]": artist,
            "album[0]": album,
            "timestamp[0]": String(Int(timestamp.timeIntervalSince1970))
        ])
    }

    func love(track: String, artist: String, sessionKey: String) async throws {
        _ = try await post(params: [
            "method": "track.love",
            "api_key": Self.apiKey,
            "sk": sessionKey,
            "track": track,
            "artist": artist
        ])
    }

    // MARK: - Stubs (replaced by Task 5 extension)

    func post(params: [String: String]) async throws -> [String: Any] {
        throw LastFMError.invalidResponse
    }

    func get(params: [String: String]) async throws -> [String: Any] {
        throw LastFMError.invalidResponse
    }
}
