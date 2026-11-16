import AnyRemoteWire
import Foundation

/// `AnyRemote-update.json`, published with every release. The app reads the
/// latest one from a fixed release-asset address (no GitHub API, so no rate
/// limit).
public struct UpdateManifest: Codable, Equatable, Sendable {
    public var version: String
    public var protocolVersion: UInt16
    public var minimumSystemVersion: String
    /// The release zip; must be HTTPS.
    public var url: URL
    public var size: Int
    /// Lowercase hex SHA-256 of the zip.
    public var sha256: String
    /// Short notes by language (`en`, `zh-Hans`), one line per change.
    public var notes: [String: [String]]
    /// The release page, for the full notes.
    public var releaseURL: URL?

    public init(version: String, protocolVersion: UInt16, minimumSystemVersion: String, url: URL, size: Int,
                sha256: String, notes: [String: [String]], releaseURL: URL?) {
        self.version = version
        self.protocolVersion = protocolVersion
        self.minimumSystemVersion = minimumSystemVersion
        self.url = url
        self.size = size
        self.sha256 = sha256
        self.notes = notes
        self.releaseURL = releaseURL
    }

    /// Where every release puts its manifest.
    public static let latestURL = URL(string:
        "https://github.com/localhost-copilot/anyremote/releases/latest/download/AnyRemote-update.json")!

    public static func decode(_ data: Data) throws -> UpdateManifest {
        let manifest: UpdateManifest
        do {
            manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
        } catch {
            throw UpdateError.badManifest(error.localizedDescription)
        }
        guard AppVersion(manifest.version) != nil else { throw UpdateError.badManifest("version \(manifest.version)") }
        guard manifest.url.scheme == "https" || manifest.url.isFileURL || Self.isLocalTestURL(manifest.url) else {
            throw UpdateError.badManifest("the download isn't HTTPS")
        }
        guard manifest.sha256.count == 64, manifest.sha256.allSatisfy(\.isHexDigit), manifest.size > 0 else {
            throw UpdateError.badManifest("checksum")
        }
        return manifest
    }

    /// Plain HTTP only from this Mac, for testing against a local server.
    private static func isLocalTestURL(_ url: URL) -> Bool {
        url.scheme == "http" && (url.host == "127.0.0.1" || url.host == "localhost")
    }

    /// Newer than `current`?
    public func isNewer(than current: String) -> Bool {
        guard let mine = AppVersion(version), let theirs = AppVersion(current) else { return false }
        return mine > theirs
    }

    /// Runs on this Mac's system?
    public var supportsThisSystem: Bool {
        let parts = minimumSystemVersion.split(separator: ".").compactMap { Int($0) }
        let required = OperatingSystemVersion(majorVersion: parts.first ?? 0, minorVersion: parts.count > 1 ? parts[1] : 0,
                                              patchVersion: parts.count > 2 ? parts[2] : 0)
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(required)
    }

    /// The notes in the first of `languages` they come in, else English.
    public func notes(preferring languages: [String]) -> [String] {
        for language in languages {
            if let lines = notes[language] { return lines }
            if let base = language.split(separator: "-").first, let lines = notes[String(base)] { return lines }
        }
        return notes["en"] ?? notes.values.first ?? []
    }
}

public enum UpdateError: Error, LocalizedError, Equatable {
    case badManifest(String)
    case download(String)
    case checksum
    case archive(String)
    case signature(String)
    case wrongApp(String)
    case install(String)

    public var errorDescription: String? {
        switch self {
        case .badManifest(let detail): "The update information is invalid (\(detail))."
        case .download(let detail): "The update couldn't be downloaded: \(detail)"
        case .checksum: "The downloaded update is damaged (checksum mismatch)."
        case .archive(let detail): "The downloaded update couldn't be opened: \(detail)"
        case .signature(let detail): "The downloaded update isn't signed like this AnyRemote: \(detail)"
        case .wrongApp(let detail): "The downloaded update isn't the expected app: \(detail)"
        case .install(let detail): "The update couldn't be installed: \(detail)"
        }
    }
}
