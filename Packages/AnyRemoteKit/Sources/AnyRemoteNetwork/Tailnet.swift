import Darwin
import Foundation
import Network
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Tailnet")

/// What the embedded tailnet node (AnyRemoteTailnet, linked by the app)
/// offers the network code: connections and UDP ports as ordinary sockets.
/// A protocol, so that this package builds and tests without the node.
public protocol TailnetSockets: AnyObject, Sendable {
    /// Connects to host:port over the tailnet, blocking up to `timeout`;
    /// returns a connected stream socket.
    func dial(host: String, port: UInt16, timeout: TimeInterval) throws -> Int32
    /// Listens on `port`; each accepted connection arrives on the returned
    /// socket as a record (see `TailnetListener`). Closing it stops listening.
    func listen(port: UInt16) throws -> Int32
    /// Opens a UDP port (0: any free one): a datagram socket whose datagrams
    /// carry the peer's address in front (see `DatagramSocket`), and the port.
    func openDatagram(port: UInt16) throws -> (descriptor: Int32, port: UInt16)
    func closeDatagram(port: UInt16)
    /// This node's tailnet addresses, IPv4 first.
    var addresses: [String] { get }
}

/// A failure the tailnet node reported, in its words.
public struct TailnetError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }

    public var errorDescription: String? {
        if message.contains("connection refused") { return "The host refused the connection. Is AnyRemote running there?" }
        if message.contains("deadline exceeded") || message.contains("timed out") { return "The host is unreachable." }
        return message
    }
}

/// Addresses on a tailnet: Tailscale gives its devices addresses in
/// 100.64.0.0/10 and fd7a:115c:a1e0::/48.
public enum TailnetAddress {
    public static func isTailnet(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            let bytes = withUnsafeBytes(of: &v4) { Array($0) }
            return bytes[0] == 100 && bytes[1] & 0xc0 == 64
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            return bytes.prefix(6) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]
        }
        return false
    }

    /// This Mac's addresses on the Tailscale app's tunnel (a utun interface):
    /// empty unless the app is connected, which routes the tailnet's
    /// addresses through the system. IPv4 first.
    public static func systemAddresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var v4: [String] = [], v6: [String] = []
        var cursor = list
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            guard String(cString: entry.ifa_name).hasPrefix("utun"), let address = entry.ifa_addr,
                  entry.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(address.pointee.sa_len)
            guard address.pointee.sa_family == AF_INET || address.pointee.sa_family == AF_INET6,
                  getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let text = String(cString: host)
            guard isTailnet(text) else { continue }
            if address.pointee.sa_family == AF_INET { v4.append(text) } else { v6.append(text) }
        }
        return v4 + v6
    }

    /// The Tailscale app is connected on this Mac.
    public static var systemTailscaleIsConnected: Bool { !systemAddresses().isEmpty }
}

/// This Mac's addresses on its local networks, which another Mac may reach
/// without Tailscale (across routed subnets, where Bonjour doesn't go).
public enum LocalAddresses {
    /// IPv4 addresses of interfaces that are up, other than loopback, the
    /// tailnet's tunnel, virtual machines' networks and link-local ones.
    public static func current() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var found: [String] = []
        var cursor = list
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            let name = String(cString: entry.ifa_name)
            guard let address = entry.ifa_addr, address.pointee.sa_family == AF_INET,
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  !name.hasPrefix("utun"), !name.hasPrefix("ipsec"), !isVirtualMachineBridge(name) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
                              NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            if !text.hasPrefix("169.254."), !TailnetAddress.isTailnet(text), !found.contains(text) { found.append(text) }
        }
        return found
    }

    /// A network between this Mac and its virtual machines (vmnet, used by
    /// Virtualization, OrbStack and VMware, numbers its bridges from 100).
    /// Only this Mac reaches it, and many Macs share its addresses
    /// (192.168.64.1). The Thunderbolt Bridge, `bridge0`, does link Macs.
    public static func isVirtualMachineBridge(_ interface: String) -> Bool {
        guard interface.hasPrefix("bridge"), let number = Int(interface.dropFirst("bridge".count)) else { return false }
        return number >= 100
    }

    /// 10/8, 172.16/12 or 192.168/16.
    public static func isPrivateIPv4(_ host: String) -> Bool {
        var target = in_addr()
        guard inet_pton(AF_INET, host, &target) == 1 else { return false }
        let address = UInt32(bigEndian: target.s_addr)
        return address >> 24 == 10 || address >> 20 == 0xac1 || address >> 16 == 0xc0a8
    }
}

/// Which of several ways to a host answers, before connecting by one: each
/// is tried at once (a TCP connection, closed as soon as it opens), and the
/// first in order that answers wins. A later one that answers first wins
/// only if the earlier ones haven't within `grace`.
public enum RouteProbe {
    public static func preferred(_ routes: [HostRoute], timeout: TimeInterval = 3,
                                 grace: TimeInterval = 0.5) async -> Int? {
        guard routes.count > 1 else { return routes.isEmpty ? nil : 0 }
        let queue = DispatchQueue(label: "anyremote.route-probe")
        let state = ProbeState(count: routes.count)
        return await withCheckedContinuation { continuation in
            state.finish = { continuation.resume(returning: $0) }
            for (index, route) in routes.enumerated() {
                let transport = route.makeStream()
                state.transports.append(transport)
                transport.stateHandler = { [weak transport] change in
                    switch change {
                    case .ready: state.settle(index, answered: true, queue: queue, grace: grace)
                    case .failed: state.settle(index, answered: false, queue: queue, grace: grace)
                    case .cancelled: return
                    }
                    transport?.cancel()
                }
                transport.start(queue: queue)
            }
            queue.asyncAfter(deadline: .now() + timeout) { state.decide(final: true) }
        }
    }
}

/// Confined to the probe's queue.
private final class ProbeState: @unchecked Sendable {
    var results: [Bool?]
    var transports: [any StreamTransport] = []
    var finish: ((Int?) -> Void)?
    private var graceScheduled = false

    init(count: Int) { results = Array(repeating: nil, count: count) }

    func settle(_ index: Int, answered: Bool, queue: DispatchQueue, grace: TimeInterval) {
        guard results[index] == nil else { return }
        results[index] = answered
        if answered, !graceScheduled {
            graceScheduled = true
            queue.asyncAfter(deadline: .now() + grace) { [self] in decide(final: true) }
        }
        decide(final: false)
    }

    /// The first that answered once all before it are settled; at the end,
    /// the first that answered at all.
    func decide(final: Bool) {
        guard let finish else { return }
        for (index, result) in results.enumerated() {
            if result == true { return conclude(finish, index) }
            if result == nil, !final { return }
        }
        if final || !results.contains(where: { $0 == nil }) { conclude(finish, nil) }
    }

    private func conclude(_ finish: (Int?) -> Void, _ index: Int?) {
        self.finish = nil
        transports.forEach { $0.cancel() }
        finish(index)
    }
}

/// Path MTU for sizing video datagrams.
public enum PathMTU {
    /// The tailnet's tunnel, the Tailscale app's or the embedded node's:
    /// 1280 bytes leaves room for WireGuard on any path.
    public static let tailnet = 1280

    /// The MTU of a network interface ("en0", "utun4").
    public static func interface(_ name: String) -> Int? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var cursor = list
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            guard let address = entry.ifa_addr, address.pointee.sa_family == AF_LINK, let data = entry.ifa_data,
                  String(cString: entry.ifa_name) == name else { continue }
            return Int(data.assumingMemoryBound(to: if_data.self).pointee.ifi_mtu)
        }
        return nil
    }

    /// The largest UDP payload a datagram on this path may have so that it
    /// isn't split into IP fragments: the MTU less the IP and UDP headers,
    /// and no more than `limit`. A 1400-byte datagram crossing the tailnet
    /// went out as two fragments (1280 + 188 bytes), doubling the packets
    /// through WireGuard and losing the whole datagram when either piece is lost.
    public static func datagramPayload(mtu: Int?, ipv6: Bool, limit: Int = 1400) -> Int {
        guard let mtu, mtu >= 576 else { return limit }
        return min(limit, mtu - (ipv6 ? 40 : 20) - 8)
    }
}

/// Accepts the connections the tailnet node receives on a port: each one
/// is a record on the listener socket, 64 bytes: the connection's
/// descriptor (big-endian int32), the length of the remote address, and
/// the address ("ip:port").
public final class TailnetListener: @unchecked Sendable {
    public static let recordSize = 64

    private let descriptor: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var buffer = Data()
    public var onConnection: (@Sendable (any StreamTransport) -> Void)?
    public var onClose: (@Sendable () -> Void)?

    public init(sockets: any TailnetSockets, port: UInt16, queue: DispatchQueue) throws {
        descriptor = try sockets.listen(port: port)
        self.queue = queue
    }

    public func start() {
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        let descriptor = descriptor
        source.setEventHandler { [weak self] in self?.readRecords() }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    public func cancel() {
        source?.cancel()
        source = nil
    }

    deinit {
        if let source { source.cancel() } else { close(descriptor) }
    }

    private func readRecords() {
        var chunk = [UInt8](repeating: 0, count: Self.recordSize * 16)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                buffer.append(chunk, count: count)
                continue
            }
            if count == 0 || (errno != EAGAIN && errno != EINTR) {
                log.notice("tailnet listener closed")
                cancel()
                onClose?()
            }
            break
        }
        while buffer.count >= Self.recordSize {
            let record = Data(buffer.prefix(Self.recordSize))
            buffer.removeFirst(Self.recordSize)
            guard let (connection, remote) = Self.parse(record) else { continue }
            onConnection?(SocketStreamTransport(descriptor: connection, remoteEndpoint: remote))
        }
    }

    static func parse(_ record: Data) -> (Int32, NWEndpoint?)? {
        guard record.count == recordSize else { return nil }
        let bytes = [UInt8](record)
        let descriptor = Int32(bitPattern: UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
                               | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        let length = min(Int(bytes[4]), recordSize - 5)
        let address = String(decoding: bytes[5..<(5 + length)], as: UTF8.self)
        return (descriptor, NWEndpoint(hostPortString: address))
    }
}

extension NWEndpoint {
    /// "ip:port" or "[ipv6]:port".
    init?(hostPortString text: String) {
        guard let colon = text.lastIndex(of: ":"), let port = UInt16(text[text.index(after: colon)...]),
              let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let host = text[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        self = .hostPort(host: NWEndpoint.Host(host), port: nwPort)
    }
}

/// How a viewer reaches a host.
public enum HostRoute: Sendable {
    /// Through this Mac's own network, with Network.framework: the LAN, or
    /// the tailnet when the Tailscale app is connected here.
    case network(NWEndpoint)
    /// Through this app's embedded tailnet node, to a tailnet address.
    case tailnet(any TailnetSockets, host: String, port: UInt16)

    public var endpoint: NWEndpoint {
        switch self {
        case .network(let endpoint): endpoint
        case let .tailnet(_, host, port): .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        }
    }

    public var isTailnet: Bool {
        if case .tailnet = self { return true }
        return false
    }

    /// A new connection to the host's control port; `bulk` for transfers.
    public func makeStream(bulk: Bool = false) -> any StreamTransport {
        switch self {
        case .network(let endpoint):
            return NetworkStreamTransport(NWConnection(to: endpoint, using: ControlConnection.parameters(bulk: bulk)))
        case let .tailnet(sockets, host, port):
            return SocketStreamTransport(remoteEndpoint: endpoint) {
                try sockets.dial(host: host, port: port, timeout: 8)
            }
        }
    }

    /// A socket for the host's datagrams and the host's datagram address.
    /// `connectedHost` is the numeric address the control connection
    /// reached (which, for a Bonjour service, only the connection knows).
    public func makeDatagramSocket(connectedHost: String?, port: UInt16,
                                   queue: DispatchQueue) throws -> (DatagramSocket, SocketAddress) {
        switch self {
        case .network:
            guard let connectedHost, let address = SocketAddress.resolve(host: connectedHost, port: port) else {
                throw ConnectionError.closed
            }
            return (try DatagramSocket(for: address, queue: queue), address)
        case let .tailnet(sockets, host, _):
            guard let address = SocketAddress.resolve(host: host, port: port) else { throw ConnectionError.closed }
            let opened = try sockets.openDatagram(port: 0)
            let socket = DatagramSocket(tailnetDescriptor: opened.descriptor, queue: queue) { [weak sockets] in
                sockets?.closeDatagram(port: opened.port)
            }
            return (socket, address)
        }
    }
}

/// The embedded node's state, as `ar_tailnet_status` reports it.
public struct TailnetStatus: Codable, Equatable, Sendable {
    /// tailscaled's backend state: NoState, NeedsLogin, NeedsMachineAuth,
    /// Starting, Running, Stopped.
    public var state: String
    /// Where to sign in while the state is NeedsLogin.
    public var authURL: String?
    public var tailnet: String?
    /// The signed-in user's login name.
    public var user: String?
    /// This device.
    public var device: Peer?
    public var peers: [Peer]
    /// Problems tailscaled sees ("not connected to the coordination server").
    public var health: [String]?
    public var droppedInbound: UInt64?
    public var droppedOutbound: UInt64?

    public struct Peer: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var hostName: String
        public var dnsName: String
        /// "macOS", "iOS", "linux"…
        public var os: String
        public var online: Bool
        public var addresses: [String]
        /// The direct endpoint in use; empty while relayed.
        public var curAddr: String?
        /// The DERP region relaying, when not direct.
        public var relay: String?
        /// A peer relay in use, when not direct.
        public var peerRelay: String?
        public var keyExpiry: Date?

        /// The IPv4 address, which AnyRemote connects to.
        public var preferredAddress: String? { addresses.first { !$0.contains(":") } ?? addresses.first }

        /// The peer's address on a local network, when Tailscale reaches it
        /// directly there: AnyRemote can then go without Tailscale.
        public var lanAddress: String? {
            guard let current = curAddr, let colon = current.lastIndex(of: ":") else { return nil }
            let host = String(current[..<colon])
            return LocalAddresses.isPrivateIPv4(host) ? host : nil
        }

        public var path: Path {
            if !(curAddr ?? "").isEmpty { return .direct }
            if !(peerRelay ?? "").isEmpty { return .peerRelay }
            if !(relay ?? "").isEmpty { return .derp }
            return .unknown
        }

        /// The short name: the MagicDNS label, else the host name.
        public var name: String {
            dnsName.split(separator: ".").first.map(String.init) ?? hostName
        }
    }

    public enum Path: Sendable { case direct, peerRelay, derp, unknown }

    private enum CodingKeys: String, CodingKey {
        case state, authURL, tailnet, user, device = "self", peers, health, droppedInbound, droppedOutbound
    }

    public var isRunning: Bool { state == "Running" }

    public static func decode(_ json: Data) -> TailnetStatus? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            // Go writes RFC 3339 with up to nine digits of seconds' fractions;
            // a key's expiry needs none of them.
            let text = try decoder.singleValueContainer().decode(String.self)
            let whole = text.replacingOccurrences(of: #"\.[0-9]+"#, with: "", options: .regularExpression)
            guard let date = ISO8601DateFormatter().date(from: whole) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: text))
            }
            return date
        }
        return try? decoder.decode(TailnetStatus.self, from: json)
    }
}
