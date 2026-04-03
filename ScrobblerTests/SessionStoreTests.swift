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
