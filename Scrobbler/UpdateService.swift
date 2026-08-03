import Foundation
import AppKit

struct GitHubRelease: Decodable {
    let tagName: String
    let name: String
    let body: String?
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case assets
    }
}

struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

enum UpdateError: Error, LocalizedError {
    case invalidResponse
    case httpError(Int)
    case noReleaseAsset(String)
    case invalidVersion(String)
    case checksumMismatch
    case invalidApplication
    case installationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "GitHub returned an invalid update response."
        case .httpError(let status): return "GitHub returned HTTP status \(status)."
        case .noReleaseAsset(let name): return "The release is missing \(name)."
        case .invalidVersion(let version): return "The release has an invalid version: \(version)."
        case .checksumMismatch: return "The downloaded update failed its checksum verification."
        case .invalidApplication: return "The downloaded update is not a valid Scrobbler app."
        case .installationFailed(let message): return "The update could not be installed: \(message)"
        }
    }
}

struct UpdateService {
    static let owner = "Tobybarnes"
    static let repository = "scrobbler"
    static let appAssetName = "Scrobbler.zip"
    static let checksumAssetName = "Scrobbler.zip.sha256"

    let session: URLSessionProtocol
    let appURL: URL
    let currentVersion: String

    init(session: URLSessionProtocol = URLSession.shared,
         appURL: URL = Bundle.main.bundleURL,
         currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0") {
        self.session = session
        self.appURL = appURL
        self.currentVersion = currentVersion
    }

    var releasesURL: URL {
        URL(string: "https://api.github.com/repos/\(Self.owner)/\(Self.repository)/releases/latest")!
    }

    func checkForUpdate() async throws -> GitHubRelease? {
        var request = URLRequest(url: releasesURL)
        request.setValue("Scrobbler/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.invalidResponse }
        guard http.statusCode == 200 else { throw UpdateError.httpError(http.statusCode) }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let releaseVersion = Self.version(from: release.tagName) else {
            throw UpdateError.invalidVersion(release.tagName)
        }

        let installedVersion = Self.version(from: currentVersion) ?? []
        return Self.isNewer(releaseVersion, than: installedVersion) ? release : nil
    }

    func install(_ release: GitHubRelease) async throws {
        guard let appAsset = release.assets.first(where: { $0.name == Self.appAssetName }) else {
            throw UpdateError.noReleaseAsset(Self.appAssetName)
        }
        guard let checksumAsset = release.assets.first(where: { $0.name == Self.checksumAssetName }) else {
            throw UpdateError.noReleaseAsset(Self.checksumAssetName)
        }

        let (archive, archiveResponse) = try await session.data(for: URLRequest(url: appAsset.browserDownloadURL))
        guard (archiveResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.httpError((archiveResponse as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let (checksumData, checksumResponse) = try await session.data(for: URLRequest(url: checksumAsset.browserDownloadURL))
        guard (checksumResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.httpError((checksumResponse as? HTTPURLResponse)?.statusCode ?? 0)
        }

        let expectedChecksum = String(decoding: checksumData, as: UTF8.self)
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" })
            .first
            .map(String.init)
        guard let expectedChecksum else { throw UpdateError.invalidResponse }
        guard Self.sha256(archive) == expectedChecksum.lowercased() else {
            throw UpdateError.checksumMismatch
        }

        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Scrobbler-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        let archiveURL = stagingDirectory.appendingPathComponent(Self.appAssetName)
        try archive.write(to: archiveURL, options: .atomic)
        try runDitto(arguments: ["-x", "-k", archiveURL.path, stagingDirectory.path])

        let extractedApp = stagingDirectory.appendingPathComponent("Scrobbler.app")
        try validateApplication(at: extractedApp, expectedVersion: release.tagName)
        try replaceInstalledApplication(with: extractedApp)
    }

    private func validateApplication(at url: URL, expectedVersion: String) throws {
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/MacOS/Scrobbler").path),
              let bundle = Bundle(url: url),
              bundle.bundleIdentifier == "com.tobybarnes.scrobbler",
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              Self.version(from: version) == Self.version(from: expectedVersion) else {
            throw UpdateError.invalidApplication
        }
    }

    private func replaceInstalledApplication(with newApp: URL) throws {
        let fileManager = FileManager.default
        let backupURL = appURL.deletingLastPathComponent()
            .appendingPathComponent(".Scrobbler-old-\(UUID().uuidString).app")

        do {
            try fileManager.moveItem(at: appURL, to: backupURL)
            try fileManager.moveItem(at: newApp, to: appURL)
            try? fileManager.removeItem(at: backupURL)
        } catch {
            try? fileManager.removeItem(at: appURL)
            try? fileManager.moveItem(at: backupURL, to: appURL)
            throw UpdateError.installationFailed(error.localizedDescription)
        }
    }

    private func runDitto(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.installationFailed("Archive extraction failed.")
        }
    }

    static func version(from value: String) -> [Int]? {
        let trimmed = value.lowercased().hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = trimmed.split(separator: ".")
        guard !parts.isEmpty, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return parts.map { Int($0)! }
    }

    private static func isNewer(_ candidate: [Int], than installed: [Int]) -> Bool {
        let count = max(candidate.count, installed.count)
        for index in 0..<count {
            let candidatePart = index < candidate.count ? candidate[index] : 0
            let installedPart = index < installed.count ? installed[index] : 0
            if candidatePart != installedPart { return candidatePart > installedPart }
        }
        return false
    }

    private static func sha256(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
