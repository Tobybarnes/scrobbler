import XCTest
@testable import Scrobbler

// Mock URLSession via protocol injection
class MockURLSession: URLSessionProtocol {
    var responseData: Data = Data()
    var statusCode: Int = 200
    var error: Error?
    var requests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if let e = error { throw e }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (responseData, response)
    }
}

class LastFMClientTests: XCTestCase {
    var mock: MockURLSession!
    var client: LastFMClient!

    override func setUp() {
        super.setUp()
        mock = MockURLSession()
        client = LastFMClient(
            credentials: LastFMCredentials(apiKey: "test-api-key", sharedSecret: "test-shared-secret"),
            session: mock
        )
    }

    func test_getToken_returns_token_on_success() async throws {
        mock.responseData = #"{"token":"abc123"}"#.data(using: .utf8)!
        let token = try await client.getToken()
        XCTAssertEqual(token, "abc123")
    }

    func test_getToken_signs_the_authorization_request() async throws {
        mock.responseData = Data(#"{"token":"abc123"}"#.utf8)

        _ = try await client.getToken()

        let request = try XCTUnwrap(mock.requests.first)
        let url = try XCTUnwrap(request.url)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let parameters = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(parameters["method"], "auth.getToken")
        XCTAssertEqual(parameters["api_key"], "test-api-key")
        // Independently calculated from the documented Last.fm signing format.
        XCTAssertEqual(parameters["api_sig"], "d1dea6f4c45a79edade0e0ca37c6333e")
        XCTAssertNil(parameters["shared_secret"])
    }

    func test_getToken_throws_apiError_on_lastfm_error() async throws {
        mock.responseData = #"{"error":8,"message":"Operation failed"}"#.data(using: .utf8)!
        do {
            _ = try await client.getToken()
            XCTFail("Expected error")
        } catch LastFMError.apiError(let code, _) {
            XCTAssertEqual(code, 8)
        }
    }

    func test_getSession_returns_session_key() async throws {
        mock.responseData = #"{"session":{"key":"sessionkey123","name":"tobybarnes","subscriber":0}}"#.data(using: .utf8)!
        let key = try await client.getSession(token: "token123")
        XCTAssertEqual(key, "sessionkey123")
    }

    func test_updateNowPlaying_sends_post_request() async throws {
        mock.responseData = "{\"nowplaying\":{\"artist\":{\"corrected\":\"0\",\"#text\":\"Tame Impala\"}}}".data(using: .utf8)!
        // Should not throw
        try await client.updateNowPlaying(
            track: "Elephant",
            artist: "Tame Impala",
            album: "Lonerism",
            duration: 212,
            sessionKey: "sk123"
        )
    }

    func test_scrobble_sends_post_request() async throws {
        mock.responseData = #"{"scrobbles":{"@attr":{"accepted":1,"ignored":0}}}"#.data(using: .utf8)!
        try await client.scrobble(
            track: "Elephant",
            artist: "Tame Impala",
            album: "Lonerism",
            timestamp: Date(timeIntervalSince1970: 1700000000),
            sessionKey: "sk123"
        )
    }

    func test_scrobble_accepts_string_response_counts() async throws {
        mock.responseData = Data(#"{"scrobbles":{"@attr":{"accepted":"1","ignored":"0"}}}"#.utf8)

        try await client.scrobble(track: "Elephant", artist: "Tame Impala", album: "Lonerism",
                                  timestamp: Date(), sessionKey: "sk123")
    }

    func test_scrobble_throws_when_lastfm_ignores_the_track() async throws {
        mock.responseData = Data(##"{"scrobbles":{"@attr":{"accepted":0,"ignored":1},"scrobble":{"ignoredMessage":{"code":"3","#text":"Timestamp too old"}}}}"##.utf8)

        do {
            try await client.scrobble(track: "Elephant", artist: "Tame Impala", album: "Lonerism",
                                      timestamp: Date(), sessionKey: "sk123")
            XCTFail("An ignored scrobble must not be reported as accepted")
        } catch LastFMError.scrobbleIgnored(let message) {
            XCTAssertEqual(message, "Timestamp too old")
        }
    }

    func test_scrobble_requires_confirmation_of_acceptance() async throws {
        for response in ["{}", "not JSON", #"{"scrobbles":{"@attr":{"accepted":0,"ignored":0}}}"#] {
            mock.responseData = Data(response.utf8)
            do {
                try await client.scrobble(track: "Elephant", artist: "Tame Impala", album: "Lonerism",
                                          timestamp: Date(), sessionKey: "sk123")
                XCTFail("Missing confirmation must not be treated as a successful scrobble")
            } catch LastFMError.invalidResponse {
                // The response cannot establish that Last.fm accepted the scrobble.
            }
        }
    }

    func test_love_sends_post_request() async throws {
        mock.responseData = #"{}"#.data(using: .utf8)!
        try await client.love(track: "Elephant", artist: "Tame Impala", sessionKey: "sk123")
    }

    func test_http_error_throws_httpError() async throws {
        mock.statusCode = 500
        mock.responseData = Data()
        do {
            _ = try await client.getToken()
            XCTFail("Expected error")
        } catch LastFMError.httpError(let code) {
            XCTAssertEqual(code, 500)
        }
    }
}
