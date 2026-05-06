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
    static let apiKey = Secrets.apiKey
    static let secret = Secrets.secret
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

}

// MARK: - Network calls

extension LastFMClient {

    // MARK: GET / POST helpers
    // `fileprivate` (not `private`) so the class-body methods (updateNowPlaying,
    // scrobble, love) in the same file can call these helpers.

    fileprivate func get(params: [String: String]) async throws -> Data {
        var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false)!
        var queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        queryItems.append(URLQueryItem(name: "format", value: "json"))
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.setValue("Scrobbler/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LastFMError.invalidResponse }
        guard http.statusCode == 200 else { throw LastFMError.httpError(http.statusCode) }
        try checkForAPIError(data)
        return data
    }

    fileprivate func post(params: [String: String]) async throws -> Data {
        var allParams = params
        allParams["format"] = "json"
        let sig = Self.apiSignature(params: params, secret: Self.secret)
        allParams["api_sig"] = sig

        var request = URLRequest(url: Self.baseURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Scrobbler/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = allParams
            .map { "\($0.key.urlEncoded)=\($0.value.urlEncoded)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LastFMError.invalidResponse }
        guard http.statusCode == 200 else { throw LastFMError.httpError(http.statusCode) }
        try checkForAPIError(data)
        return data
    }

    private func checkForAPIError(_ data: Data) throws {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["error"] as? Int else { return }
        let message = json["message"] as? String ?? "Unknown error"
        throw LastFMError.apiError(code, message)
    }

    // MARK: Auth

    func getToken() async throws -> String {
        let data = try await get(params: [
            "method": "auth.getToken",
            "api_key": Self.apiKey
        ])
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String else {
            throw LastFMError.invalidResponse
        }
        return token
    }

    func getSession(token: String) async throws -> String {
        let params: [String: String] = [
            "method": "auth.getSession",
            "api_key": Self.apiKey,
            "token": token
        ]
        let sig = Self.apiSignature(params: params, secret: Self.secret)
        let data = try await get(params: params.merging(["api_sig": sig]) { $1 })
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = json["session"] as? [String: Any],
              let key = session["key"] as? String else {
            throw LastFMError.invalidResponse
        }
        return key
    }
}

// MARK: - URL encoding helper
// For application/x-www-form-urlencoded bodies, only unreserved characters
// (A-Z a-z 0-9 - . _ ~) may appear unencoded. Everything else — including
// &, =, + and spaces — must be percent-encoded.

private extension String {
    var urlEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
