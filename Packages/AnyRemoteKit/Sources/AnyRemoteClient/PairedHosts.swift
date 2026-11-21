import AnyRemoteNetwork
import AnyRemoteWire
import Foundation

/// Which ways AnyRemote may reach a paired Mac.
public enum RoutePreference: String, Codable, Sendable, CaseIterable {
    /// Every way at once; the local network when it answers.
    case automatic
    /// Never through Tailscale.
    case localOnly
    /// Always through Tailscale: for networks where a local connection
    /// opens but video doesn't get through.
    case tailnetOnly
}

/// A Mac this one has paired with (or that offered the way back).
public struct PairedHost: Codable, Hashable, Sendable, Identifiable {
    /// The host's stable ID once known; before the first connection, the address.
    public var id: String
    public var name: String
    /// "host:port" for manual entries; nil for hosts reached through Bonjour.
    public var address: String?
    public var bonjourName: String?
    /// The key to connect with: the Mac's own for this one, or its legacy
    /// shared code (Macs paired before 0.31). Nil until paired, for a Mac
    /// added by address.
    public var credential: PairingCredential?
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
    /// Its address on the tailnet, as it last said: where it's reached when
    /// it isn't on this network.
    public var tailnetAddress: String?
    /// Its addresses on local networks, as it last said: tried before the
    /// tailnet when it isn't seen nearby (Bonjour stays within a subnet).
    public var localAddresses: [String]?
    /// Nil: automatic.
    public var routePreference: RoutePreference?

    public init(id: String, name: String, address: String?, bonjourName: String?, credential: PairingCredential?,
                lastConnected: Date? = nil, fromPeer: Bool = false, sharesBack: Bool = true,
                maximumBitRate: Int? = nil, frameRate: Int? = nil, tailnetAddress: String? = nil,
                localAddresses: [String]? = nil) {
        self.id = id
        self.name = name
        self.address = address
        self.bonjourName = bonjourName
        self.credential = credential
        self.lastConnected = lastConnected
        self.fromPeer = fromPeer
        self.sharesBack = sharesBack
        self.maximumBitRate = maximumBitRate
        self.frameRate = frameRate
        self.tailnetAddress = tailnetAddress
        self.localAddresses = localAddresses
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, address, bonjourName, credential, pairingCode, lastConnected, fromPeer, sharesBack,
             maximumBitRate, frameRate, tailnetAddress, localAddresses, routePreference
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        address = try container.decodeIfPresent(String.self, forKey: .address)
        bonjourName = try container.decodeIfPresent(String.self, forKey: .bonjourName)
        // Before 0.31 every Mac was reached with its shared code.
        credential = try container.decodeIfPresent(PairingCredential.self, forKey: .credential)
            ?? container.decodeIfPresent(String.self, forKey: .pairingCode).flatMap(PairingCode.init)
                .map(PairingCredential.legacy)
        lastConnected = try container.decodeIfPresent(Date.self, forKey: .lastConnected)
        fromPeer = try container.decodeIfPresent(Bool.self, forKey: .fromPeer) ?? false
        // Pairings from before this setting existed share back too.
        sharesBack = try container.decodeIfPresent(Bool.self, forKey: .sharesBack) ?? true
        maximumBitRate = try container.decodeIfPresent(Int.self, forKey: .maximumBitRate)
        frameRate = try container.decodeIfPresent(Int.self, forKey: .frameRate)
        tailnetAddress = try container.decodeIfPresent(String.self, forKey: .tailnetAddress)
        localAddresses = try container.decodeIfPresent([String].self, forKey: .localAddresses)
        routePreference = try? container.decodeIfPresent(RoutePreference.self, forKey: .routePreference)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(address, forKey: .address)
        try container.encodeIfPresent(bonjourName, forKey: .bonjourName)
        try container.encodeIfPresent(credential, forKey: .credential)
        try container.encodeIfPresent(lastConnected, forKey: .lastConnected)
        try container.encode(fromPeer, forKey: .fromPeer)
        try container.encode(sharesBack, forKey: .sharesBack)
        try container.encodeIfPresent(maximumBitRate, forKey: .maximumBitRate)
        try container.encodeIfPresent(frameRate, forKey: .frameRate)
        try container.encodeIfPresent(tailnetAddress, forKey: .tailnetAddress)
        try container.encodeIfPresent(localAddresses, forKey: .localAddresses)
        try container.encodeIfPresent(routePreference, forKey: .routePreference)
    }
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
        case added, keyChanged, addressChanged, removed, unchanged
    }

    /// An offer adds the Mac, or takes the key of a Mac already known when
    /// that's new (it paired again, or this Mac had only its legacy code)
    /// and, for a Mac added by an offer, the address it connected from (it
    /// moved: another network, a new DHCP lease). A withdrawal removes only
    /// a Mac that was added by an offer, never one paired here by hand.
    static func applying(_ pairing: PeerPairing, address: String?, ownID: String,
                         to hosts: [PairedHost]) -> ([PairedHost], PeerPairingOutcome) {
        guard pairing.hostID != ownID else { return (hosts, .unchanged) }
        var hosts = hosts
        let index = hosts.firstIndex { $0.id == pairing.hostID }
        guard let credential = pairing.credential else {
            guard let index, hosts[index].fromPeer else { return (hosts, .unchanged) }
            hosts.remove(at: index)
            return (hosts, .removed)
        }
        guard !credential.isLegacy else { return (hosts, .unchanged) }
        let byAddress = pairing.usesAddress && address != nil
        if let index {
            var outcome = PeerPairingOutcome.unchanged
            if hosts[index].fromPeer, byAddress, hosts[index].address != address {
                hosts[index].address = address
                hosts[index].bonjourName = nil
                outcome = .addressChanged
            }
            // A key of its own beats the legacy code, but one paired here
            // stays: the offer is for connecting back, not instead.
            if hosts[index].credential != credential, hosts[index].fromPeer || hosts[index].credential?.isLegacy != false {
                hosts[index].credential = credential
                outcome = .keyChanged
            }
            return (hosts, outcome)
        }
        hosts.append(PairedHost(id: pairing.hostID, name: pairing.name, address: byAddress ? address : nil,
                                bonjourName: byAddress ? nil : pairing.name, credential: credential,
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
