# Scrobbler Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS menu bar app in Swift that polls Apple Music every 5 seconds and scrobbles listening history to Last.fm.

**Architecture:** `MusicPoller` publishes `TrackState?` via Combine. `ScrobbleEngine` subscribes, accumulates real playback time, and fires Last.fm API calls at the correct thresholds. `AppDelegate` owns the `NSStatusItem` and wires all components together. Data flows one way: `MusicPoller` → `ScrobbleEngine` → `LastFMClient`.

**Tech Stack:** Swift 5.9+, AppKit, Combine, XCTest, CryptoKit (MD5), Security framework (Keychain), osascript (Apple Music detection). Deployment target: macOS 13.0. Project generation: xcodegen.

---

## File Map

| File | Responsibility |
|---|---|
| `project.yml` | xcodegen project definition |
| `Scrobbler/Info.plist` | LSUIElement = YES, Apple Events privacy string |
| `Scrobbler/main.swift` | App entry point — creates delegate, starts run loop |
| `Scrobbler/Models.swift` | `PlayerState` enum, `TrackState` struct, `TrackIdentity` struct |
| `Scrobbler/SessionStore.swift` | Keychain save/load/delete for Last.fm session key |
| `Scrobbler/LastFMClient.swift` | API signing + all Last.fm HTTP calls |
| `Scrobbler/MusicPoller.swift` | AppleScript runner, output parser, Combine publisher |
| `Scrobbler/ScrobbleEngine.swift` | Playback accumulation, scrobble threshold logic, state machine |
| `Scrobbler/MenuController.swift` | Builds and updates the `NSMenu` from app state |
| `Scrobbler/AppDelegate.swift` | `NSStatusItem` owner, wires all components, auth flow |
| `ScrobblerTests/ScrobbleEngineTests.swift` | Logic tests for accumulation and scrobble decisions |
| `ScrobblerTests/LastFMSigningTests.swift` | API signature generation tests |
| `ScrobblerTests/SessionStoreTests.swift` | Keychain round-trip tests |
| `ScrobblerTests/MusicPollerParserTests.swift` | AppleScript output parser tests |

---

## Chunk 1: Scaffolding, Models, SessionStore

### Task 1: Bootstrap the Xcode project with xcodegen

**Files:**
- Create: `project.yml`
- Create: `Scrobbler/Info.plist`
- Create: `Scrobbler/main.swift`

- [ ] **Step 1: Install xcodegen**

```bash
brew install xcodegen
```

Expected: `xcodegen version X.X.X` prints after install.

- [ ] **Step 2: Write project.yml**

```yaml
name: Scrobbler
options:
  bundleIdPrefix: com.tobybarnes
  deploymentTarget:
    macOS: "13.0"
  defaultConfig: Debug
targets:
  Scrobbler:
    type: application
    platform: macOS
    sources:
      - path: Scrobbler
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.tobybarnes.scrobbler
        INFOPLIST_FILE: Scrobbler/Info.plist
        SWIFT_VERSION: "5.9"
        CODE_SIGN_STYLE: Automatic
        ENABLE_HARDENED_RUNTIME: YES
        MACOSX_DEPLOYMENT_TARGET: "13.0"
  ScrobblerTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: ScrobblerTests
    dependencies:
      - target: Scrobbler
    settings:
      base:
        SWIFT_VERSION: "5.9"
        MACOSX_DEPLOYMENT_TARGET: "13.0"
```

- [ ] **Step 3: Write Scrobbler/Info.plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Scrobbler needs access to Apple Music to track what you're listening to.</string>
    <key>CFBundleName</key>
    <string>Scrobbler</string>
    <key>CFBundleIdentifier</key>
    <string>com.tobybarnes.scrobbler</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
</dict>
</plist>
```

- [ ] **Step 4: Create source directories and main.swift**

```bash
mkdir -p Scrobbler ScrobblerTests
```

Write `Scrobbler/main.swift`:

```swift
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
```

- [ ] **Step 5: Create a temporary AppDelegate stub so the project compiles**

Write `Scrobbler/AppDelegate.swift` (stub — will be replaced in Task 9):

```swift
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {}
}
```

- [ ] **Step 6: Generate the Xcode project**

```bash
xcodegen generate
```

Expected output: `✅ Created project at Scrobbler.xcodeproj`

- [ ] **Step 7: Verify the project builds**

```bash
xcodebuild -scheme Scrobbler -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 8: Commit**

```bash
git add project.yml Scrobbler/Info.plist Scrobbler/main.swift Scrobbler/AppDelegate.swift Scrobbler.xcodeproj
git commit -m "feat: bootstrap Xcode project with xcodegen"
```

---

### Task 2: Define data models

**Files:**
- Create: `Scrobbler/Models.swift`
- Create: `ScrobblerTests/ModelsTests.swift`

- [ ] **Step 1: Write the failing test**

Write `ScrobblerTests/ModelsTests.swift`:

```swift
import XCTest
@testable import Scrobbler

class ModelsTests: XCTestCase {

    func test_playerState_cases_exist() {
        let _ = PlayerState.playing
        let _ = PlayerState.paused
        let _ = PlayerState.stopped
    }

    func test_trackState_stores_all_fields() {
        let state = TrackState(
            track: "Elephant",
            artist: "Tame Impala",
            album: "Lonerism",
            duration: 212.0,
            position: 45.0,
            playerState: .playing
        )
        XCTAssertEqual(state.track, "Elephant")
        XCTAssertEqual(state.artist, "Tame Impala")
        XCTAssertEqual(state.album, "Lonerism")
        XCTAssertEqual(state.duration, 212.0)
        XCTAssertEqual(state.position, 45.0)
        XCTAssertEqual(state.playerState, .playing)
    }

    func test_trackIdentity_equality() {
        let a = TrackIdentity(track: "Elephant", artist: "Tame Impala")
        let b = TrackIdentity(track: "Elephant", artist: "Tame Impala")
        let c = TrackIdentity(track: "Let It Happen", artist: "Tame Impala")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -scheme Scrobbler -destination 'platform=macOS' 2>&1 | grep -E "(error:|FAILED|PASSED)"
```

Expected: compile error — `PlayerState`, `TrackState`, `TrackIdentity` not defined.

- [ ] **Step 3: Write Models.swift**

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme Scrobbler -destination 'platform=macOS' 2>&1 | grep -E "(error:|FAILED|PASSED|Test Suite)"
```

Expected: `Test Suite 'ModelsTests' passed`

- [ ] **Step 5: Commit**

```bash
git add Scrobbler/Models.swift ScrobblerTests/ModelsTests.swift
git commit -m "feat: add core data models"
```

---

### Task 3: Implement SessionStore

**Files:**
- Create: `Scrobbler/SessionStore.swift`
- Create: `ScrobblerTests/SessionStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Write `ScrobblerTests/SessionStoreTests.swift`:

```swift
import XCTest
@testable import Scrobbler

class SessionStoreTests: XCTestCase {

    // Use a test-specific service to avoid colliding with the real keychain entry
    var store: SessionStore!

    override func setUp() {
        super.setUp()
        store = SessionStore(service: "com.tobybarnes.scrobbler.tests", account: "lastfm-session-test")
        try? store.delete()   // clean slate
    }

    override func tearDown() {
        try? store.delete()
        super.tearDown()
    }

    func test_load_returns_nil_when_nothing_saved() {
        XCTAssertNil(store.load())
    }

    func test_save_and_load_roundtrip() throws {
        try store.save("test-session-key-abc")
        XCTAssertEqual(store.load(), "test-session-key-abc")
    }

    func test_save_overwrites_existing_value() throws {
        try store.save("first-key")
        try store.save("second-key")
        XCTAssertEqual(store.load(), "second-key")
    }

    func test_delete_removes_value() throws {
        try store.save("some-key")
        try store.delete()
        XCTAssertNil(store.load())
    }

    func test_delete_on_empty_does_not_throw() {
        XCTAssertNoThrow(try store.delete())
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -scheme Scrobbler -destination 'platform=macOS' 2>&1 | grep -E "(error:|FAILED|SessionStore)"
```

Expected: compile error — `SessionStore` not defined.

- [ ] **Step 3: Write SessionStore.swift**

```swift
import Foundation
import Security

enum SessionStoreError: Error {
    case saveFailed(OSStatus)
    case deleteFailed(OSStatus)
}

class SessionStore {
    private let service: String
    private let account: String

    init(service: String = "com.tobybarnes.scrobbler",
         account: String = "lastfm-session") {
        self.service = service
        self.account = account
    }

    func save(_ sessionKey: String) throws {
        guard let data = sessionKey.data(using: .utf8) else { return }

        // Delete any existing entry first (update is fiddly, delete+add is reliable)
        try? delete()

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SessionStoreError.saveFailed(status)
        }
    }

    func load() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        return key
    }

    func delete() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SessionStoreError.deleteFailed(status)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme Scrobbler -destination 'platform=macOS' 2>&1 | grep -E "(FAILED|PASSED|SessionStore)"
```

Expected: `Test Suite 'SessionStoreTests' passed`

- [ ] **Step 5: Commit**

```bash
git add Scrobbler/SessionStore.swift ScrobblerTests/SessionStoreTests.swift
git commit -m "feat: add SessionStore for Keychain session key persistence"
```

---

## Chunk 2: LastFMClient

### Task 4: API signing utility

Last.fm write API calls require a signature: concatenate all parameter key+value pairs sorted alphabetically, append the shared secret, then take the MD5 hash. The `format` parameter is excluded from signing.

**Files:**
- Create: `Scrobbler/LastFMClient.swift` (signing section only)
- Create: `ScrobblerTests/LastFMSigningTests.swift`

- [ ] **Step 1: Write signing tests**

Write `ScrobblerTests/LastFMSigningTests.swift`:

```swift
import XCTest
@testable import Scrobbler

class LastFMSigningTests: XCTestCase {

    func test_md5_of_known_string() {
        // echo -n "hello" | md5
        XCTAssertEqual("hello".md5Hash, "5d41402abc4b2a76b9719d911017c592")
    }

    func test_api_signature_sorts_params_and_appends_secret() {
        // Given params that would sort as: api_key, method, track
        // Concatenated: api_keyABCmethodtrack.lovetrackElephant
        // Plus secret: api_keyABCmethodtrack.lovetrackElephantSECRET
        let params: [String: String] = [
            "track": "Elephant",
            "method": "track.love",
            "api_key": "ABC"
        ]
        let sig = LastFMClient.apiSignature(params: params, secret: "SECRET")
        let expected = "api_keyABCmethodtrack.lovetrackElephant".appending("SECRET").md5Hash
        XCTAssertEqual(sig, expected)
    }

    func test_api_signature_excludes_format_param() {
        let paramsWithFormat: [String: String] = [
            "api_key": "ABC",
            "method": "track.love",
            "format": "json"
        ]
        let paramsWithout: [String: String] = [
            "api_key": "ABC",
            "method": "track.love"
        ]
        let sigWith = LastFMClient.apiSignature(params: paramsWithFormat, secret: "SECRET")
        let sigWithout = LastFMClient.apiSignature(params: paramsWithout, secret: "SECRET")
        XCTAssertEqual(sigWith, sigWithout)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -scheme Scrobbler -destination 'platform=macOS' 2>&1 | grep -E "(error:|LastFMSigning)"
```

Expected: compile error — `LastFMClient` not defined.

- [ ] **Step 3: Write the signing implementation in LastFMClient.swift**

Write `Scrobbler/LastFMClient.swift` (signing + error model only — network calls in next task). This establishes the complete class body including the `session` property and both initialisers, so Task 5 only needs to add extension methods without modifying the class body.

```swift
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
    static let apiKey = "[redacted-api-key]"
    static let secret = "[redacted-shared-secret]"
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
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme Scrobbler -destination 'platform=macOS' 2>&1 | grep -E "(FAILED|PASSED|LastFMSigning)"
```

Expected: `Test Suite 'LastFMSigningTests' passed`

- [ ] **Step 5: Commit**

```bash
git add Scrobbler/LastFMClient.swift ScrobblerTests/LastFMSigningTests.swift
git commit -m "feat: add LastFMClient with API signing"
```

---

### Task 5: Last.fm network calls

All API calls use `async/await`. Read methods use GET; write methods use POST with a form-encoded body.

**Files:**
- Modify: `Scrobbler/LastFMClient.swift` (add network calls)
- Create: `ScrobblerTests/LastFMClientTests.swift`

- [ ] **Step 1: Write network call tests with a mock session**

Write `ScrobblerTests/LastFMClientTests.swift`:

```swift
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
        client = LastFMClient(session: mock)
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
        mock.responseData = #"{"nowplaying":{"artist":{"corrected":"0","#text":"Tame Impala"}}}"#.data(using: .utf8)!
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
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -scheme Scrobbler -destination 'platform=macOS' 2>&1 | grep -E "(error:|LastFMClient)"
```

Expected: compile errors — `URLSessionProtocol`, network methods not defined.

- [ ] **Step 3: Append network methods to LastFMClient.swift**

`URLSessionProtocol`, the class body, and both initialisers are already written by Task 4. Append only this extension to the bottom of `Scrobbler/LastFMClient.swift`:

```swift
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

    // MARK: POST helper

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

    // MARK: Error check

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
```


- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme Scrobbler -destination 'platform=macOS' 2>&1 | grep -E "(FAILED|PASSED|LastFMClient)"
```

Expected: `Test Suite 'LastFMClientTests' passed`

- [ ] **Step 5: Commit**

```bash
git add Scrobbler/LastFMClient.swift ScrobblerTests/LastFMClientTests.swift
git commit -m "feat: add LastFMClient network calls"
```

---

## Chunk 3: MusicPoller + ScrobbleEngine

### Task 6: MusicPoller

The poller runs an AppleScript every 5 seconds on a background queue and publishes the result on the main queue via a Combine `PassthroughSubject<TrackState?, Never>`. The AppleScript runner is injectable for testing.

**Files:**
- Create: `Scrobbler/MusicPoller.swift`
- Create: `ScrobblerTests/MusicPollerParserTests.swift`

- [ ] **Step 1: Write parser tests**

The parser is the testable part — it converts the raw AppleScript output string into a `TrackState?`. The timer and script runner aren't tested directly.

Write `ScrobblerTests/MusicPollerParserTests.swift`:

```swift
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
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -scheme Scrobbler -destination 'platform=macOS' 2>&1 | grep -E "(error:|MusicPoller)"
```

Expected: compile error.

- [ ] **Step 3: Write MusicPoller.swift**

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme Scrobbler -destination 'platform=macOS' 2>&1 | grep -E "(FAILED|PASSED|MusicPoller)"
```

Expected: `Test Suite 'MusicPollerParserTests' passed`

- [ ] **Step 5: Commit**

```bash
git add Scrobbler/MusicPoller.swift ScrobblerTests/MusicPollerParserTests.swift
git commit -m "feat: add MusicPoller with injectable script runner and parser"
```

---

### Task 7: ScrobbleEngine

The engine consumes `TrackState?` updates, accumulates actual played time, detects new tracks and repeats, and fires Last.fm API calls at the right moments. It is pure logic — no timers, no UI.

**Files:**
- Create: `Scrobbler/ScrobbleEngine.swift`
- Create: `ScrobblerTests/ScrobbleEngineTests.swift`

- [ ] **Step 1: Write the engine tests**

Write `ScrobblerTests/ScrobbleEngineTests.swift`:

```swift
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
        XCTAssertEqual(mockClient.updateNowPlayingCalls.count, 1)
        XCTAssertEqual(mockClient.updateNowPlayingCalls[0].track, "Elephant")
    }

    func test_same_track_does_not_repeat_updateNowPlaying() async {
        let state = makePlaying(track: "Elephant", position: 0)
        await engine.update(state)
        fakeNow = fakeNow.addingTimeInterval(5)
        await engine.update(makePlaying(track: "Elephant", position: 5))
        XCTAssertEqual(mockClient.updateNowPlayingCalls.count, 1)
    }

    // MARK: scrobble threshold

    func test_no_scrobble_before_30_seconds() async {
        await engine.update(makePlaying(track: "Elephant", position: 0, duration: 212))
        advanceTime(by: 25)
        await engine.update(makePlaying(track: "Elephant", position: 25, duration: 212))
        XCTAssertEqual(mockClient.scrobbleCalls.count, 0)
    }

    func test_scrobble_fires_after_threshold_met() async {
        // duration 60s → threshold = min(30s, 60s*0.5=30s) = 30s
        await engine.update(makePlaying(track: "Short Track", position: 0, duration: 60))
        advanceTime(by: 30)
        await engine.update(makePlaying(track: "Short Track", position: 30, duration: 60))
        XCTAssertEqual(mockClient.scrobbleCalls.count, 1)
        XCTAssertEqual(mockClient.scrobbleCalls[0].track, "Short Track")
    }

    func test_scrobble_fires_only_once_per_play() async {
        await engine.update(makePlaying(track: "Short Track", position: 0, duration: 60))
        advanceTime(by: 31)
        await engine.update(makePlaying(track: "Short Track", position: 31, duration: 60))
        advanceTime(by: 5)
        await engine.update(makePlaying(track: "Short Track", position: 36, duration: 60))
        XCTAssertEqual(mockClient.scrobbleCalls.count, 1)
    }

    func test_long_track_scrobbles_at_4_minutes() async {
        // duration 20 min → 50% = 10 min, capped at 4 min
        let duration: TimeInterval = 20 * 60
        await engine.update(makePlaying(track: "Long Track", position: 0, duration: duration))
        advanceTime(by: 240) // 4 minutes
        await engine.update(makePlaying(track: "Long Track", position: 240, duration: duration))
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
        XCTAssertEqual(mockClient.scrobbleCalls.count, 0)
    }

    // MARK: Track change

    func test_track_change_resets_and_fires_updateNowPlaying_for_new_track() async {
        await engine.update(makePlaying(track: "Track A", position: 0, duration: 60))
        advanceTime(by: 5)
        await engine.update(makePlaying(track: "Track B", position: 0, duration: 60))
        XCTAssertEqual(mockClient.updateNowPlayingCalls.count, 2)
        XCTAssertEqual(mockClient.updateNowPlayingCalls[1].track, "Track B")
    }

    func test_track_change_before_threshold_does_not_scrobble_old_track() async {
        await engine.update(makePlaying(track: "Track A", position: 0, duration: 60))
        advanceTime(by: 10)
        await engine.update(makePlaying(track: "Track B", position: 0, duration: 60))
        XCTAssertEqual(mockClient.scrobbleCalls.count, 0)
    }

    // MARK: Repeat detection

    func test_position_decrease_triggers_new_play() async {
        await engine.update(makePlaying(track: "Elephant", position: 30, duration: 212))
        // Position jumped back — same track on repeat
        await engine.update(makePlaying(track: "Elephant", position: 5, duration: 212))
        XCTAssertEqual(mockClient.updateNowPlayingCalls.count, 2)
    }

    // MARK: Nil state (Music.app quit)

    func test_nil_state_suspends_accumulation() async {
        await engine.update(makePlaying(track: "Elephant", position: 0, duration: 60))
        advanceTime(by: 20)
        await engine.update(nil)  // Music.app quit
        advanceTime(by: 20)
        await engine.update(makePlaying(track: "Elephant", position: 20, duration: 60))
        // Should have accumulated ~20s, not 40s
        XCTAssertEqual(mockClient.scrobbleCalls.count, 0)
    }

    // MARK: Scrobbling disabled

    func test_scrobbling_disabled_suppresses_all_api_calls() async {
        engine.isScrobblingEnabled = false
        await engine.update(makePlaying(track: "Elephant", position: 0, duration: 60))
        advanceTime(by: 35)
        await engine.update(makePlaying(track: "Elephant", position: 35, duration: 60))
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
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -scheme Scrobbler -destination 'platform=macOS' 2>&1 | grep -E "(error:|ScrobbleEngine)"
```

Expected: compile error.

- [ ] **Step 3: Write ScrobbleEngine.swift**

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme Scrobbler -destination 'platform=macOS' 2>&1 | grep -E "(FAILED|PASSED|ScrobbleEngine)"
```

Expected: `Test Suite 'ScrobbleEngineTests' passed`

- [ ] **Step 5: Commit**

```bash
git add Scrobbler/ScrobbleEngine.swift ScrobblerTests/ScrobbleEngineTests.swift
git commit -m "feat: add ScrobbleEngine with playback accumulation and scrobble logic"
```

---

## Chunk 4: MenuController + AppDelegate

### Task 8: MenuController

Builds the `NSMenu` and updates it based on app state. All menu content is driven by a single `AppState` value — no incremental patching.

**Files:**
- Create: `Scrobbler/MenuController.swift`

No unit tests for this task — `NSMenu` construction is an AppKit concern tested by running the app. Build verification is the gate.

- [ ] **Step 1: Write MenuController.swift**

```swift
import AppKit

// All state needed to render the menu
struct AppState {
    enum Auth {
        case notAuthenticated
        case pendingApproval(token: String)
        case authenticated
    }

    var auth: Auth = .notAuthenticated
    var currentTrack: TrackState? = nil
    var isScrobblingEnabled: Bool = true
    var hasAPIError: Bool = false
    var recentArtists: [(artist: String, count: Int)] = []
}

class MenuController {
    // Called by AppDelegate when menu items are tapped
    var onConnect: (() -> Void)?
    var onApproved: ((String) -> Void)?      // passes the pending token
    var onPauseResume: (() -> Void)?
    var onLove: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onQuit: (() -> Void)?

    private var state = AppState()

    func buildMenu(for state: AppState) -> NSMenu {
        self.state = state
        let menu = NSMenu()

        switch state.auth {
        case .notAuthenticated:
            menu.addItem(withTitle: "Not connected to Last.fm", action: nil, keyEquivalent: "")
                .isEnabled = false
            menu.addItem(NSMenuItem.separator())
            menu.addItem(makeItem("Connect to Last.fm", action: #selector(connectTapped), target: self))

        case .pendingApproval(let token):
            menu.addItem(withTitle: "Waiting for approval…", action: nil, keyEquivalent: "")
                .isEnabled = false
            menu.addItem(makeItem("I've approved it", action: #selector(approvedTapped(_:)), target: self)
                .also { $0.representedObject = token })

        case .authenticated:
            buildAuthenticatedMenu(menu)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem("Quit", action: #selector(quitTapped), target: self))
        return menu
    }

    private func buildAuthenticatedMenu(_ menu: NSMenu) {
        // Error banner
        if state.hasAPIError {
            let errItem = NSMenuItem(title: "⚠ Last.fm unreachable", action: nil, keyEquivalent: "")
            errItem.isEnabled = false
            menu.addItem(errItem)
            menu.addItem(NSMenuItem.separator())
        }

        // Now Playing section
        let nowPlayingHeader = NSMenuItem(title: "NOW PLAYING", action: nil, keyEquivalent: "")
        nowPlayingHeader.isEnabled = false
        nowPlayingHeader.attributedTitle = sectionHeader("NOW PLAYING")
        menu.addItem(nowPlayingHeader)

        if let track = state.currentTrack, track.playerState == .playing {
            let dot = state.isScrobblingEnabled ? "● " : ""
            let trackItem = NSMenuItem(title: "\(dot)\(track.track)", action: nil, keyEquivalent: "")
            trackItem.isEnabled = false
            menu.addItem(trackItem)

            let metaItem = NSMenuItem(title: "  \(track.artist) · \(track.album)", action: nil, keyEquivalent: "")
            metaItem.isEnabled = false
            menu.addItem(metaItem)
        } else {
            let nothingItem = NSMenuItem(title: "Not playing", action: nil, keyEquivalent: "")
            nothingItem.isEnabled = false
            menu.addItem(nothingItem)
        }

        // Recent Scrobbles section (hidden if empty)
        if !state.recentArtists.isEmpty {
            menu.addItem(NSMenuItem.separator())
            let recentHeader = NSMenuItem(title: "RECENT SCROBBLES", action: nil, keyEquivalent: "")
            recentHeader.isEnabled = false
            recentHeader.attributedTitle = sectionHeader("RECENT SCROBBLES")
            menu.addItem(recentHeader)

            for entry in state.recentArtists.prefix(5) {
                let item = NSMenuItem(title: "\(entry.artist)  ×\(entry.count)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        // Actions
        let loveItem = makeItem("♡ Love this track", action: #selector(loveTapped), target: self)
        loveItem.isEnabled = state.currentTrack?.playerState == .playing
        menu.addItem(loveItem)

        let pauseTitle = state.isScrobblingEnabled ? "⏸ Pause scrobbling" : "▶ Resume scrobbling"
        menu.addItem(makeItem(pauseTitle, action: #selector(pauseResumeTapped), target: self))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem("Disconnect from Last.fm", action: #selector(disconnectTapped), target: self))
    }

    // MARK: - Actions

    @objc private func connectTapped()           { onConnect?() }
    @objc private func approvedTapped(_ sender: NSMenuItem) {
        onApproved?(sender.representedObject as? String ?? "")
    }
    @objc private func pauseResumeTapped()       { onPauseResume?() }
    @objc private func loveTapped()              { onLove?() }
    @objc private func disconnectTapped()        { onDisconnect?() }
    @objc private func quitTapped()              { onQuit?() }

    // MARK: - Helpers

    private func makeItem(_ title: String, action: Selector, target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        return item
    }

    private func sectionHeader(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
    }
}

private extension NSMenuItem {
    func also(_ configure: (NSMenuItem) -> Void) -> NSMenuItem {
        configure(self)
        return self
    }
}
```

- [ ] **Step 2: Verify the project still builds**

```bash
xcodebuild -scheme Scrobbler -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Scrobbler/MenuController.swift
git commit -m "feat: add MenuController for state-driven NSMenu construction"
```

---

### Task 9: AppDelegate — wire everything together

This task replaces the stub `AppDelegate` with the real implementation. It owns the `NSStatusItem`, subscribes to `MusicPoller`, drives `ScrobbleEngine`, manages auth state, and keeps `MenuController` up to date.

**Files:**
- Modify: `Scrobbler/AppDelegate.swift` (replace stub)

- [ ] **Step 1: Replace AppDelegate stub with the full implementation**

```swift
import AppKit
import Combine

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Components

    private let sessionStore = SessionStore()
    private let lastFMClient = LastFMClient()
    private var scrobbleEngine: ScrobbleEngine?
    private let poller = MusicPoller()
    private let menuController = MenuController()

    // MARK: - Status item

    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()

    // MARK: - App state

    private var appState = AppState() {
        didSet { rebuildMenu() }
    }

    private var recentScrobbleCounts: [String: Int] = [:]  // artist → count

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupMenuCallbacks()
        checkAuthAndStart()
    }

    // MARK: - Status item setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusItemTitle()
        statusItem.menu = menuController.buildMenu(for: appState)
    }

    private func updateStatusItemTitle() {
        let title: String
        let dotColor: NSColor?

        switch appState.auth {
        case .notAuthenticated, .pendingApproval:
            title = "♫ Not connected"
            dotColor = .systemOrange

        case .authenticated:
            if let track = appState.currentTrack, track.playerState == .playing {
                let truncated = String(track.track.prefix(30))
                let ellipsis = track.track.count > 30 ? "…" : ""
                title = "♫ \(truncated)\(ellipsis) — \(track.artist)"
            } else {
                title = "♫ Not playing"
            }
            if appState.hasAPIError {
                dotColor = .systemOrange
            } else if !appState.isScrobblingEnabled {
                dotColor = .secondaryLabelColor
            } else if appState.currentTrack?.playerState == .playing {
                dotColor = .systemRed
            } else {
                dotColor = nil
            }
        }

        let attributed = NSMutableAttributedString(string: title)
        if let color = dotColor {
            let dot = NSAttributedString(string: " ●", attributes: [.foregroundColor: color])
            attributed.append(dot)
        }
        statusItem.button?.attributedTitle = attributed
    }

    private func rebuildMenu() {
        updateStatusItemTitle()
        statusItem.menu = menuController.buildMenu(for: appState)
    }

    // MARK: - Auth

    private func checkAuthAndStart() {
        if let key = sessionStore.load() {
            appState.auth = .authenticated
            startPolling(sessionKey: key)
        } else {
            appState.auth = .notAuthenticated
        }
    }

    private func startPolling(sessionKey: String) {
        let engine = ScrobbleEngine(client: lastFMClient, sessionKey: sessionKey)
        engine.onScrobble = { [weak self] artist in
            self?.recordScrobble(artist: artist)
        }
        scrobbleEngine = engine

        poller.publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.appState.currentTrack = state
                    await self.scrobbleEngine?.update(state)
                }
            }
            .store(in: &cancellables)

        poller.start()
    }

    // MARK: - Menu callbacks

    private func setupMenuCallbacks() {
        menuController.onConnect = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.handleConnect()
            }
        }

        menuController.onApproved = { [weak self] token in
            Task { @MainActor [weak self] in
                await self?.handleApproved(token: token)
            }
        }

        menuController.onPauseResume = { [weak self] in
            guard let self else { return }
            self.appState.isScrobblingEnabled.toggle()
            self.scrobbleEngine?.isScrobblingEnabled = self.appState.isScrobblingEnabled
        }

        menuController.onLove = { [weak self] in
            guard let self,
                  let track = self.appState.currentTrack,
                  track.playerState == .playing else { return }
            self.scrobbleEngine?.loveCurrentTrack(track: track.track, artist: track.artist)
        }

        menuController.onDisconnect = { [weak self] in
            self?.handleDisconnect()
        }

        menuController.onQuit = {
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Auth flow

    private func handleConnect() async {
        do {
            let token = try await lastFMClient.getToken()
            appState.auth = .pendingApproval(token: token)
            let urlString = "https://www.last.fm/api/auth/?api_key=\(LastFMClient.apiKey)&token=\(token)"
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        } catch {
            showAlert("Couldn't connect to Last.fm", message: error.localizedDescription)
        }
    }

    private func handleApproved(token: String) async {
        do {
            let sessionKey = try await lastFMClient.getSession(token: token)
            try sessionStore.save(sessionKey)
            appState.auth = .authenticated
            appState.hasAPIError = false
            startPolling(sessionKey: sessionKey)
        } catch LastFMError.apiError(14, _) {
            showAlert(
                "Not approved yet",
                message: "It looks like you haven't approved access yet. Try again after approving on Last.fm."
            )
            // Keep .pendingApproval state so user can try again without restarting flow
        } catch LastFMError.apiError(15, _) {
            showAlert(
                "Authorisation expired",
                message: "The authorisation expired. Please try connecting again."
            )
            appState.auth = .notAuthenticated
        } catch {
            showAlert("Authorisation failed", message: error.localizedDescription)
            appState.auth = .notAuthenticated
        }
    }

    private func handleDisconnect() {
        poller.stop()
        cancellables.removeAll()
        scrobbleEngine = nil
        try? sessionStore.delete()
        appState = AppState()   // reset to defaults
        appState.auth = .notAuthenticated
    }

    // MARK: - Scrobble tracking (for recent artists list)

    func recordScrobble(artist: String) {
        recentScrobbleCounts[artist, default: 0] += 1
        appState.recentArtists = recentScrobbleCounts
            .sorted { $0.value > $1.value }
            .map { (artist: $0.key, count: $0.value) }
    }

    // MARK: - Helpers

    private func showAlert(_ title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
```

- [ ] **Step 2: Verify the project builds cleanly**

```bash
xcodebuild -scheme Scrobbler -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Run all tests to confirm nothing regressed**

```bash
xcodebuild test -scheme Scrobbler -destination 'platform=macOS' 2>&1 | grep -E "(FAILED|PASSED|Test Suite 'All')"
```

Expected: all suites pass, 0 failures.

- [ ] **Step 4: Commit**

```bash
git add Scrobbler/AppDelegate.swift Scrobbler/MenuController.swift
git commit -m "feat: add AppDelegate and MenuController, wire all components"
```

---

### Task 10: Smoke test the running app

- [ ] **Step 1: Open the app in Xcode and run it**

```bash
open Scrobbler.xcodeproj
```

Press ⌘R to run. The menu bar should show `♫ Not connected ●` (amber dot).

- [ ] **Step 2: Authenticate with Last.fm**

Click the menu bar item → "Connect to Last.fm". Your browser opens Last.fm's auth page. Approve it. Return to the app and click "I've approved it".

Expected: menu bar updates to `♫ Not playing` (no dot). Console should show no errors.

- [ ] **Step 3: Play a track in Apple Music**

Expected within 5 seconds: menu bar updates to `♫ Track Name — Artist ●` (red dot).

After 30+ seconds of play (on a track longer than 60s), check your Last.fm profile — the scrobble should appear.

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "feat: scrobbler v1.0 complete"
```
