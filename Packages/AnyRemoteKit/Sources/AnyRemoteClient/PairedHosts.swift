import AnyRemoteNetwork
import AnyRemoteWire
import Foundation

/// A host this viewer knows the pairing code of.
public struct PairedHost: Codable, Hashable, Sendable, Identifiable {
    /// The host's stable ID once known; before the first connection, the address.
    public var id: String
    public var name: String
    /// "host:port" for manual entries; nil for hosts reached through Bonjour.
    public var address: String?
    public var bonjourName: String?
    public var pairingCode: String
    public var lastConnected: Date?

    public init(id: String, name: String, address: String?, bonjourName: String?, pairingCode: String,
                lastConnected: Date? = nil) {
        self.id = id
        self.name = name
        self.address = address
        self.bonjourName = bonjourName
        self.pairingCode = pairingCode
        self.lastConnected = lastConnected
    }

    public var code: PairingCode? { PairingCode(pairingCode) }
}

/// Viewer-side store of paired hosts (`viewer.json`, 0600).
public final class PairedHostStore: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [PairedHost]
    private static let fileName = "viewer.json"

    public init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        hosts = AnyRemoteStorage.read(Self.fileName)
            .flatMap { try? decoder.decode([PairedHost].self, from: $0) } ?? []
    }

    public var all: [PairedHost] {
        lock.lock()
        defer { lock.unlock() }
        return hosts
    }

    public func host(id: String) -> PairedHost? { all.first { $0.id == id } }

    /// Inserts or replaces by `id`, also replacing an entry stored under `previousID`.
    public func save(_ host: PairedHost, replacing previousID: String? = nil) {
        lock.lock()
        hosts.removeAll { $0.id == host.id || (previousID != nil && $0.id == previousID) }
        hosts.append(host)
        hosts.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let snapshot = hosts
        lock.unlock()
        persist(snapshot)
    }

    public func remove(id: String) {
        lock.lock()
        hosts.removeAll { $0.id == id }
        let snapshot = hosts
        lock.unlock()
        persist(snapshot)
    }

    private func persist(_ hosts: [PairedHost]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(hosts) { try? AnyRemoteStorage.writePrivate(data, to: Self.fileName) }
    }
}
