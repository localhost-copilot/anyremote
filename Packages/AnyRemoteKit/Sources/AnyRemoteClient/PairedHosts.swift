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
    /// Added because that Mac paired with this one and offered the way back,
    /// rather than by entering its code here.
    public var fromPeer: Bool
    /// Whether that Mac may also control this one: this Mac's own code is
    /// offered to it on every connection (and withdrawn when turned off).
    public var sharesBack: Bool
    /// The most video each stream from that Mac may use, in bits per
    /// second; nil leaves it to the host.
    public var maximumBitRate: Int?
    /// Frames a second to show that Mac's windows at; nil: 60.
    public var frameRate: Int?

    public init(id: String, name: String, address: String?, bonjourName: String?, pairingCode: String,
                lastConnected: Date? = nil, fromPeer: Bool = false, sharesBack: Bool = true,
                maximumBitRate: Int? = nil, frameRate: Int? = nil) {
        self.id = id
        self.name = name
        self.address = address
        self.bonjourName = bonjourName
        self.pairingCode = pairingCode
        self.lastConnected = lastConnected
        self.fromPeer = fromPeer
        self.sharesBack = sharesBack
        self.maximumBitRate = maximumBitRate
        self.frameRate = frameRate
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, address, bonjourName, pairingCode, lastConnected, fromPeer, sharesBack, maximumBitRate, frameRate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        address = try container.decodeIfPresent(String.self, forKey: .address)
        bonjourName = try container.decodeIfPresent(String.self, forKey: .bonjourName)
        pairingCode = try container.decode(String.self, forKey: .pairingCode)
        lastConnected = try container.decodeIfPresent(Date.self, forKey: .lastConnected)
        fromPeer = try container.decodeIfPresent(Bool.self, forKey: .fromPeer) ?? false
        // Pairings from before this setting existed share back too.
        sharesBack = try container.decodeIfPresent(Bool.self, forKey: .sharesBack) ?? true
        maximumBitRate = try container.decodeIfPresent(Int.self, forKey: .maximumBitRate)
        frameRate = try container.decodeIfPresent(Int.self, forKey: .frameRate)
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

    /// Takes in a Mac's offer to be connected back to (see `PeerPairing`).
    @discardableResult
    public func apply(_ pairing: PeerPairing, address: String?, ownID: String) -> PeerPairingOutcome {
        lock.lock()
        let (updated, outcome) = Self.applying(pairing, address: address, ownID: ownID, to: hosts)
        hosts = updated
        lock.unlock()
        if outcome != .unchanged { persist(updated) }
        return outcome
    }

    public enum PeerPairingOutcome: Equatable, Sendable {
        case added, codeChanged, addressChanged, removed, unchanged
    }

    /// An offer adds the Mac, or refreshes the code of a Mac already known
    /// (it was reset there) and, for a Mac added by an offer, the address it
    /// connected from (it moved: another network, a new DHCP lease). A
    /// withdrawal removes only a Mac that was added by an offer, never one
    /// paired here by hand.
    static func applying(_ pairing: PeerPairing, address: String?, ownID: String,
                         to hosts: [PairedHost]) -> ([PairedHost], PeerPairingOutcome) {
        guard pairing.hostID != ownID else { return (hosts, .unchanged) }
        var hosts = hosts
        let index = hosts.firstIndex { $0.id == pairing.hostID }
        guard let text = pairing.pairingCode else {
            guard let index, hosts[index].fromPeer else { return (hosts, .unchanged) }
            hosts.remove(at: index)
            return (hosts, .removed)
        }
        guard let code = PairingCode(text) else { return (hosts, .unchanged) }
        let byAddress = pairing.usesAddress && address != nil
        if let index {
            var outcome = PeerPairingOutcome.unchanged
            if hosts[index].fromPeer, byAddress, hosts[index].address != address {
                hosts[index].address = address
                hosts[index].bonjourName = nil
                outcome = .addressChanged
            }
            if hosts[index].pairingCode != code.canonical {
                hosts[index].pairingCode = code.canonical
                outcome = .codeChanged
            }
            return (hosts, outcome)
        }
        hosts.append(PairedHost(id: pairing.hostID, name: pairing.name, address: byAddress ? address : nil,
                                bonjourName: byAddress ? nil : pairing.name, pairingCode: code.canonical,
                                fromPeer: true))
        hosts.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (hosts, .added)
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
