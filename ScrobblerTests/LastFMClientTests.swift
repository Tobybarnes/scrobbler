import XCTest
@testable import Scrobbler

// Mock URLSession via protocol injection
class MockURLSession: URLSessionProtocol {
    var responseData: Data = Data()
    var statusCode: Int = 200
    var error: Error?

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
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
