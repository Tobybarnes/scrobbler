import XCTest
@testable import Scrobbler

private final class SequencedURLSession: URLSessionProtocol {
    var responses: [Data]

    init(responses: [Data]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let data = responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}

final class UpdateServiceTests: XCTestCase {
    func testInstallAcceptsStandardSHA256Checksum() async throws {
        let archive = Data("abc".utf8)
        let checksum = Data("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  Scrobbler.zip\n".utf8)
        let session = SequencedURLSession(responses: [archive, checksum])
        let service = UpdateService(
            session: session,
            appURL: URL(fileURLWithPath: "/tmp/Scrobbler.app"),
            currentVersion: "1.1"
        )
        let release = GitHubRelease(
            tagName: "v1.2.0",
            name: "1.2.0",
            body: nil,
            assets: [
                GitHubReleaseAsset(name: UpdateService.appAssetName, browserDownloadURL: URL(string: "https://example.com/Scrobbler.zip")!),
                GitHubReleaseAsset(name: UpdateService.checksumAssetName, browserDownloadURL: URL(string: "https://example.com/Scrobbler.zip.sha256")!)
            ]
        )

        do {
            try await service.install(release)
            XCTFail("The deliberately invalid archive should not install")
        } catch UpdateError.checksumMismatch {
            XCTFail("A valid SHA-256 checksum was rejected")
        } catch {
            // Reaching archive validation proves checksum verification succeeded.
        }
    }
}
