import AnyRemoteNetwork
import AnyRemoteWire
import Foundation
import OSLog
import SystemConfiguration

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Host")

/// Persistent host settings: identity, pairing secret, and preferences.
///
/// Stored as JSON with 0600 permissions in
/// `~/Library/Application Support/AnyRemote/host.json` (override the folder
/// with `ANYREMOTE_HOME`). A file rather than the Keychain so a headless
/// Mac mini never blocks on a Keychain prompt and ad-hoc builds keep access.
public struct HostSettings: Codable, Equatable, Sendable {
    /// Remote windows on virtual displays matching the viewer's screens
    /// (see `RemoteDisplays`), or on this Mac's screens (`never`). Settings
    /// shows it as one switch; `always` (a fixed-size display, from an
    /// earlier version) is taken as `automatic`.
    public enum VirtualDisplayMode: String, Codable, Sendable, CaseIterable {
        case automatic
        case always
        case never
    }

    public var hostID: String
    public var pairingCode: String
    public var isEnabled: Bool
    public var port: UInt16
    public var virtualDisplay: VirtualDisplayMode
    /// Virtual display size in points (rendered at 2x) for viewers that
    /// don't tell their screens.
    public var virtualDisplayWidth: Int
    public var virtualDisplayHeight: Int
    /// Optional so settings saved before it existed still decode.
    private var mutesSharedSound: Bool?

    /// Apps whose sound plays on a viewer go quiet on this Mac meanwhile.
    public var mutesSoundWhileShared: Bool {
        get { mutesSharedSound ?? false }
        set { mutesSharedSound = newValue }
    }

    public var code: PairingCode? { PairingCode(pairingCode) }

    static func makeDefault() -> HostSettings {
        HostSettings(hostID: UUID().uuidString, pairingCode: PairingCode.generate().canonical, isEnabled: true,
                     port: 47800, virtualDisplay: .automatic, virtualDisplayWidth: 1920, virtualDisplayHeight: 1200)
    }
}

public final class HostSettingsStore: @unchecked Sendable {
    private let lock = NSLock()
    private var current: HostSettings
    private static let fileName = "host.json"

    public init() {
        if let data = AnyRemoteStorage.read(Self.fileName),
           let decoded = try? JSONDecoder().decode(HostSettings.self, from: data), decoded.code != nil {
            current = decoded
        } else {
            current = .makeDefault()
            try? Self.persist(current)
        }
    }

    public var settings: HostSettings {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public func update(_ change: (inout HostSettings) -> Void) {
        lock.lock()
        change(&current)
        let snapshot = current
        lock.unlock()
        do { try Self.persist(snapshot) } catch {
            log.error("saving host settings failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Invalidates every paired viewer.
    public func resetPairingCode() {
        update { $0.pairingCode = PairingCode.generate().canonical }
    }

    private static func persist(_ settings: HostSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AnyRemoteStorage.writePrivate(try encoder.encode(settings), to: fileName)
    }
}

public enum ComputerName {
    public static var current: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }
}
