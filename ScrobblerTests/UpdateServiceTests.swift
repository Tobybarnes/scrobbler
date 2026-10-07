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

private final class PublicReleaseURLSession: URLSessionProtocol {
    let latestReleaseURL = URL(string: "https://github.com/Tobybarnes/scrobbler/releases/tag/v1.2.4")!

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if request.url?.host == "api.github.com" {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 403,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }

        let response = HTTPURLResponse(
            url: latestReleaseURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(), response)
    }
}

private final class BackupFailureFileManager: FileManager, @unchecked Sendable {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if dstURL.lastPathComponent.hasPrefix(".Scrobbler-old-") {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

final class UpdateServiceTests: XCTestCase {
    func testCheckForUpdateDoesNotDependOnRateLimitedGitHubAPI() async throws {
        let service = UpdateService(
            session: PublicReleaseURLSession(),
            appURL: URL(fileURLWithPath: "/tmp/Scrobbler.app"),
            currentVersion: "1.2.3"
        )

        let availableRelease = try await service.checkForUpdate()
        let release = try XCTUnwrap(availableRelease)

        XCTAssertEqual(release.tagName, "v1.2.4")
        XCTAssertEqual(release.name, "1.2.4")
        XCTAssertEqual(
            release.assets.map(\.browserDownloadURL.absoluteString),
            [
                "https://github.com/Tobybarnes/scrobbler/releases/download/v1.2.4/Scrobbler.zip",
                "https://github.com/Tobybarnes/scrobbler/releases/download/v1.2.4/Scrobbler.zip.sha256"
            ]
        )
    }

    func testInstallAcceptsStandardSHA256Checksum() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = Data("abc".utf8)
        let checksum = Data("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  Scrobbler.zip\n".utf8)
        let session = SequencedURLSession(responses: [archive, checksum])
        let service = UpdateService(
            session: session,
            appURL: directory.appendingPathComponent("Scrobbler.app"),
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
        } catch UpdateError.installationFailed(let message) {
            XCTAssertEqual(message, "Archive extraction failed.")
        } catch {
            XCTFail("Expected archive extraction after checksum verification, got \(error)")
        }
    }

    func testReadOnlyInstallationExplainsHowToMoveTheApp() async throws {
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let appURL = directory.appendingPathComponent("Scrobbler.app")
        try Data("installed app".utf8).write(to: appURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        XCTAssertFalse(FileManager.default.isWritableFile(atPath: directory.path))
        let service = UpdateService(session: SequencedURLSession(responses: []), appURL: appURL)
        let release = GitHubRelease(tagName: "v1.2.4", name: "1.2.4", body: nil, assets: [])

        do {
            try await service.install(release)
            XCTFail("A read-only installation should not begin an update")
        } catch UpdateError.installationFailed(let message) {
            XCTAssertTrue(message.contains("Applications"), "The error should explain how to install a writable copy")
        } catch {
            XCTFail("Expected guidance for a read-only installation, got \(error)")
        }

        XCTAssertEqual(try Data(contentsOf: appURL), Data("installed app".utf8))
    }

    func testBackupFailurePreservesInstalledApplication() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let appURL = directory.appendingPathComponent("Scrobbler.app")
        let replacementURL = directory.appendingPathComponent("New.app")
        try Data("installed app".utf8).write(to: appURL)
        try Data("new app".utf8).write(to: replacementURL)
        let service = UpdateService(appURL: appURL, fileManager: BackupFailureFileManager())

        XCTAssertThrowsError(try service.replaceInstalledApplication(with: replacementURL))

        XCTAssertEqual(try Data(contentsOf: appURL), Data("installed app".utf8))
        XCTAssertEqual(try Data(contentsOf: replacementURL), Data("new app".utf8))
    }

    func testReplacementFailureRestoresInstalledApplication() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let appURL = directory.appendingPathComponent("Scrobbler.app")
        try Data("installed app".utf8).write(to: appURL)
        let service = UpdateService(appURL: appURL)

        XCTAssertThrowsError(try service.replaceInstalledApplication(
            with: directory.appendingPathComponent("Missing.app")
        ))

        XCTAssertEqual(try Data(contentsOf: appURL), Data("installed app".utf8))
    }

    func testValidationAcceptsIntactAdHocSignedApplication() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let appURL = try signedApplication(in: directory)

        XCTAssertNoThrow(try UpdateService().validateApplication(at: appURL, expectedVersion: "v1.2.4"))
    }

    func testValidationRejectsTamperedSignedApplication() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let appURL = try signedApplication(in: directory)
        try Data("changed after signing".utf8).write(
            to: appURL.appendingPathComponent("Contents/Resources/release.txt")
        )

        XCTAssertThrowsError(try UpdateService().validateApplication(at: appURL, expectedVersion: "v1.2.4"))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Scrobbler-updater-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func signedApplication(in directory: URL) throws -> URL {
        let appURL = directory.appendingPathComponent("Scrobbler.app")
        let contentsURL = appURL.appendingPathComponent("Contents")
        let executableDirectory = contentsURL.appendingPathComponent("MacOS")
        let resourcesDirectory = contentsURL.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resourcesDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: executableDirectory.appendingPathComponent("Scrobbler")
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.tobybarnes.scrobbler",
            "CFBundleExecutable": "Scrobbler",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.2.4",
            "CFBundleVersion": "1"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contentsURL.appendingPathComponent("Info.plist"))
        try Data("signed release".utf8).write(to: resourcesDirectory.appendingPathComponent("release.txt"))
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", appURL.path]
        try codesign.run()
        codesign.waitUntilExit()
        XCTAssertEqual(codesign.terminationStatus, 0)
        return appURL
    }
}
