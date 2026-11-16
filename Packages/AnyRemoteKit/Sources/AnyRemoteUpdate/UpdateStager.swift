import AnyRemoteWire
import CryptoKit
import Foundation

/// A downloaded release that passed every check, ready to replace the app.
public struct StagedUpdate: Equatable, Sendable {
    public let manifest: UpdateManifest
    /// The new AnyRemote.app, unpacked in the staging directory.
    public let appURL: URL
}

/// Downloads a release and checks it before anything is installed: size and
/// SHA-256 against the manifest, then the unpacked app's bundle identifier,
/// version and code signature against the running app's.
public struct UpdateStager: Sendable {
    /// Holds downloads and unpacked apps; emptied for each new download.
    public let directory: URL
    public let bundleIdentifier: String
    /// The running app's designated requirement.
    public let requirement: String

    public init(directory: URL, bundleIdentifier: String, requirement: String) {
        self.directory = directory
        self.bundleIdentifier = bundleIdentifier
        self.requirement = requirement
    }

    /// Fetches the manifest at `url`, bypassing caches.
    public static func fetchManifest(from url: URL, session: URLSession = .shared) async throws -> UpdateManifest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.setValue("AnyRemote/\(AppVersionInfo.runningAppVersion)", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateError.download(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError.download("HTTP \(http.statusCode)")
        }
        return try UpdateManifest.decode(data)
    }

    /// Downloads and checks the release; `progress` gets 0…1 on the main queue.
    public func download(_ manifest: UpdateManifest, session: URLSession = .shared,
                         progress: (@MainActor @Sendable (Double) -> Void)? = nil) async throws -> StagedUpdate {
        try reset()
        let archive = directory.appendingPathComponent("AnyRemote-\(manifest.version).zip")
        if manifest.url.isFileURL {
            try FileManager.default.copyItem(at: manifest.url, to: archive)
        } else {
            var request = URLRequest(url: manifest.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
            request.setValue("AnyRemote/\(AppVersionInfo.runningAppVersion)", forHTTPHeaderField: "User-Agent")
            let delegate = ProgressDelegate(progress)
            let downloaded: URL
            let response: URLResponse
            do {
                (downloaded, response) = try await session.download(for: request, delegate: delegate)
            } catch {
                throw UpdateError.download(error.localizedDescription)
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw UpdateError.download("HTTP \(http.statusCode)")
            }
            try FileManager.default.moveItem(at: downloaded, to: archive)
        }
        return try stage(manifest, archive: archive)
    }

    /// Checks a downloaded archive and unpacks it next to it.
    public func stage(_ manifest: UpdateManifest, archive: URL) throws -> StagedUpdate {
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard data.count == manifest.size,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == manifest.sha256.lowercased()
        else { throw UpdateError.checksum }

        let unpacked = directory.appendingPathComponent("unpacked-\(manifest.version)", isDirectory: true)
        try? FileManager.default.removeItem(at: unpacked)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path], error: UpdateError.archive)
        let apps = (try? FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)) ?? []
        guard apps.count == 1, let app = apps.first, app.pathExtension == "app" else {
            throw UpdateError.archive("expected one app, found \(apps.map(\.lastPathComponent))")
        }
        try check(app, version: manifest.version)
        return StagedUpdate(manifest: manifest, appURL: app)
    }

    /// The identity, version and signature checks, also run again just
    /// before installing (the staging directory belongs to this user).
    public func check(_ app: URL, version: String) throws {
        guard let bundle = Bundle(url: app) else { throw UpdateError.wrongApp("no bundle") }
        guard bundle.bundleIdentifier == bundleIdentifier else {
            throw UpdateError.wrongApp(bundle.bundleIdentifier ?? "no identifier")
        }
        let bundleVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard AppVersion(bundleVersion) == AppVersion(version) else {
            throw UpdateError.wrongApp("version \(bundleVersion), expected \(version)")
        }
        try CodeSignature.verify(bundleAt: app, satisfies: requirement)
    }

    private func reset() throws {
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
}

func run(_ tool: String, _ arguments: [String], error makeError: (String) -> UpdateError) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardError = pipe
    process.standardOutput = FileHandle.nullDevice
    do { try process.run() } catch { throw makeError(error.localizedDescription) }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let message = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw makeError(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Reports a download task's progress.
private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let handler: (@MainActor @Sendable (Double) -> Void)?
    private var observation: NSKeyValueObservation?

    init(_ handler: (@MainActor @Sendable (Double) -> Void)?) { self.handler = handler }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        guard let handler else { return }
        observation = task.progress.observe(\.fractionCompleted) { progress, _ in
            let fraction = progress.fractionCompleted
            DispatchQueue.main.async { MainActor.assumeIsolated { handler(fraction) } }
        }
    }
}
