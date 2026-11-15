import Foundation

/// Per-user AnyRemote state (`~/Library/Application Support/AnyRemote`,
/// or `ANYREMOTE_HOME`). Files hold secrets and are written 0600.
public enum AnyRemoteStorage {
    public static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["ANYREMOTE_HOME"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AnyRemote", isDirectory: true)
    }

    /// Writes `data` atomically, readable only by this user.
    public static func writePrivate(_ data: Data, to name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func read(_ name: String) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(name))
    }
}

