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
