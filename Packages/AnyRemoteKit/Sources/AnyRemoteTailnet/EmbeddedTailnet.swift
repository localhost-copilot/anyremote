import AnyRemoteNetwork
import CAnyRemoteTailnet
import Foundation

/// This process's embedded Tailscale node (Tailnet/, Go, linked into the
/// app): a device of its own on the user's tailnet, through which AnyRemote
/// reaches other Macs there without the Tailscale app. Thread-safe; the
/// calls that talk to the node may take a moment, so keep them off the main
/// thread.
public final class EmbeddedTailnet: TailnetSockets, @unchecked Sendable {
    public static let shared = EmbeddedTailnet()

    private init() {}

    /// Joins the tailnet as `hostname`, keeping the node's state (its keys)
    /// in `stateDirectory`. Without `authKey` the status carries a URL to
    /// sign in at. Does nothing if running already.
    public func start(stateDirectory: URL, hostname: String, controlURL: String? = nil,
                      authKey: String? = nil) throws {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let directory = strdup(stateDirectory.path), name = strdup(hostname)
        let control = controlURL.flatMap { strdup($0) }, key = authKey.flatMap { strdup($0) }
        defer { [directory, name, control, key].forEach { free($0) } }
        try Self.call { ar_tailnet_start(directory, name, control, key, $0) }
    }

    public func stop() { ar_tailnet_stop() }

    /// Nil while the node isn't running.
    public func status() -> TailnetStatus? {
        guard let json = ar_tailnet_status() else { return nil }
        defer { free(json) }
        return TailnetStatus.decode(Data(String(cString: json).utf8))
    }

    /// Asks for a new sign-in URL (after signing out, or when the last one expired).
    public func login() throws { try Self.call { ar_tailnet_login($0) } }

    /// Signs this device out; it leaves the tailnet.
    public func logout() throws { try Self.call { ar_tailnet_logout($0) } }

    // MARK: TailnetSockets

    public func dial(host: String, port: UInt16, timeout: TimeInterval) throws -> Int32 {
        let address = strdup(host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)")
        defer { free(address) }
        var descriptor: Int32 = -1
        try Self.call { ar_tailnet_dial(address, Int32(timeout * 1000), &descriptor, $0) }
        return descriptor
    }

    public func listen(port: UInt16) throws -> Int32 {
        var descriptor: Int32 = -1
        try Self.call { ar_tailnet_listen(port, &descriptor, $0) }
        return descriptor
    }

    public func openDatagram(port: UInt16) throws -> (descriptor: Int32, port: UInt16) {
        var descriptor: Int32 = -1
        var bound: UInt16 = 0
        try Self.call { ar_tailnet_open_datagram(port, &bound, &descriptor, $0) }
        return (descriptor, bound)
    }

    public func closeDatagram(port: UInt16) { ar_tailnet_close_datagram(port) }

    public var addresses: [String] {
        let addresses = status()?.device?.addresses ?? []
        return addresses.filter { !$0.contains(":") } + addresses.filter { $0.contains(":") }
    }

    private static func call(_ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard body(&message) != 0 else { return }
        defer { free(message) }
        throw TailnetError(message.map { String(cString: $0) } ?? "The embedded Tailscale node failed.")
    }
}
