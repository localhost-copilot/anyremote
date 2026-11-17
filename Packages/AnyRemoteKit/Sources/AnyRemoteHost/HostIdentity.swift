import AnyRemoteNetwork
import AnyRemoteWire
import Foundation
import OSLog
import SystemConfiguration

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Host")

/// A Mac that may control this one: the key it was given when it paired (or
/// that this Mac offered it, see `PeerPairing`).
public struct PairedViewer: Codable, Equatable, Sendable, Identifiable {
    /// The key's ID (`PairingCredential.id`).
    public var id: String
    public var name: String
    /// That Mac's own host ID, when known: pairing it again replaces this.
    public var peerID: String?
    /// Base64, 32 bytes.
    public var key: String
    public var created: Date

    public init(id: String, name: String, peerID: String?, key: String, created: Date = Date()) {
        self.id = id
        self.name = name
        self.peerID = peerID
        self.key = key
        self.created = created
    }

    public var credential: PairingCredential? { PairingCredential(id: id, key: key) }
}

/// Persistent host settings: identity, pairing keys, and preferences.
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
    /// The code every viewer used before 0.31. Macs paired with it keep
    /// working until it's removed in Settings; new installs have none.
    public var pairingCode: String?
    /// Optional so settings saved before it existed still decode.
    private var pairedViewers: [PairedViewer]?
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

    /// The legacy shared code, if this Mac still has one.
    public var legacyCode: PairingCode? { pairingCode.flatMap(PairingCode.init) }

    /// Macs that paired with a key of their own, oldest first.
    public var viewers: [PairedViewer] {
        get { pairedViewers ?? [] }
        set { pairedViewers = newValue }
    }

    /// The key a viewer names in its hello (nil: the legacy code).
    public func credential(id: String?) -> PairingCredential? {
        guard let id else { return legacyCode.map(PairingCredential.legacy) }
        return viewers.first { $0.id == id }?.credential
    }

    static func makeDefault() -> HostSettings {
        HostSettings(hostID: UUID().uuidString, pairingCode: nil, pairedViewers: [], isEnabled: true,
                     port: 47800, virtualDisplay: .automatic, virtualDisplayWidth: 1920, virtualDisplayHeight: 1200)
    }
}

public final class HostSettingsStore: @unchecked Sendable {
    private let lock = NSLock()
    private var current: HostSettings
    private static let fileName = "host.json"

    public init() {
        if let data = AnyRemoteStorage.read(Self.fileName),
           let decoded = try? JSONDecoder().decode(HostSettings.self, from: data) {
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

    /// Keeps a Mac's key, replacing any it had before.
    public func addViewer(_ viewer: PairedViewer) {
        update { settings in
            settings.viewers.removeAll { $0.id == viewer.id || (viewer.peerID != nil && $0.peerID == viewer.peerID) }
            settings.viewers.append(viewer)
        }
    }

    /// Revokes one Mac's key.
    public func removeViewer(id: String) {
        update { $0.viewers.removeAll { $0.id == id } }
    }

    /// Revokes the legacy shared code: Macs paired with it must pair again.
    public func removeLegacyCode() {
        update { $0.pairingCode = nil }
    }

    /// The key this Mac offers `peerID` for connecting back (see
    /// `PeerPairing`), made the first time.
    public func credential(forPeer peerID: String, name: String) -> PairingCredential {
        if let existing = settings.viewers.first(where: { $0.peerID == peerID }), existing.name == name,
           let credential = existing.credential {
            return credential
        }
        var result: PairingCredential?
        update { settings in
            if let existing = settings.viewers.first(where: { $0.peerID == peerID }), let credential = existing.credential {
                result = credential
                if existing.name != name, let index = settings.viewers.firstIndex(of: existing) {
                    settings.viewers[index].name = name
                }
                return
            }
            let credential = PairingCredential.generate()
            settings.viewers.append(PairedViewer(id: credential.id!, name: name, peerID: peerID, key: credential.key!))
            result = credential
        }
        return result!
    }

    /// The key this Mac's own viewer uses to reach its own host (loopback
    /// tests): the legacy code while there is one.
    public var loopbackCredential: PairingCredential {
        let settings = settings
        return settings.legacyCode.map(PairingCredential.legacy)
            ?? credential(forPeer: settings.hostID, name: ComputerName.current)
    }

    /// Revokes the key offered to `peerID`, if any. Returns its ID.
    @discardableResult
    public func revokePeer(_ peerID: String) -> String? {
        var removed: String?
        update { settings in
            removed = settings.viewers.first { $0.peerID == peerID }?.id
            settings.viewers.removeAll { $0.peerID == peerID }
        }
        return removed
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
