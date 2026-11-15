import Foundation
import Network
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Discovery")

public enum AnyRemoteService {
    public static let type = "_anyremote._tcp"
    public static let defaultPort: UInt16 = 47800
    static let hostIDKey = "id"
}

/// Accepts control connections and advertises the host over Bonjour.
public final class ControlListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue
    public var onConnection: (@Sendable (NWConnection) -> Void)?
    public var onStateChange: (@Sendable (NWListener.State) -> Void)?

    public var port: UInt16? { listener.port?.rawValue }

    public init(port: UInt16, serviceName: String?, hostID: String, queue: DispatchQueue) throws {
        self.queue = queue
        let parameters = ControlConnection.parameters()
        parameters.allowLocalEndpointReuse = true
        if port == 0 {
            listener = try NWListener(using: parameters)
        } else {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        }
        if let serviceName {
            var txt = NWTXTRecord()
            txt[AnyRemoteService.hostIDKey] = hostID
            listener.service = NWListener.Service(name: serviceName, type: AnyRemoteService.type, txtRecord: txt)
        }
    }

    public func start() {
        listener.newConnectionHandler = { [weak self] connection in
            self?.onConnection?(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                log.error("listener failed: \(String(describing: error), privacy: .public)")
            }
            self?.onStateChange?(state)
        }
        listener.start(queue: queue)
    }

    public func cancel() { listener.cancel() }
}

/// A host found on the network.
public struct DiscoveredHost: Hashable, Sendable {
    public var name: String
    public var hostID: String?
    public var endpoint: NWEndpoint

    public static func == (lhs: DiscoveredHost, rhs: DiscoveredHost) -> Bool {
        lhs.name == rhs.name && lhs.hostID == rhs.hostID && lhs.endpoint == rhs.endpoint
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(hostID)
    }
}

/// Browses for AnyRemote hosts over Bonjour.
public final class HostBrowser: @unchecked Sendable {
    private let browser: NWBrowser
    private let queue = DispatchQueue(label: "anyremote.browser")
    public var onChange: (@Sendable ([DiscoveredHost]) -> Void)?

    public init() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        browser = NWBrowser(for: .bonjourWithTXTRecord(type: AnyRemoteService.type, domain: nil), using: parameters)
    }

    public func start() {
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let hosts = results.compactMap { result -> DiscoveredHost? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                var hostID: String?
                if case let .bonjour(txt) = result.metadata { hostID = txt[AnyRemoteService.hostIDKey] }
                return DiscoveredHost(name: name, hostID: hostID, endpoint: result.endpoint)
            }
            self?.onChange?(hosts.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                log.error("browser failed: \(String(describing: error), privacy: .public)")
            }
        }
        browser.start(queue: queue)
    }

    public func cancel() { browser.cancel() }
}

extension NWEndpoint {
    /// The numeric host of a resolved endpoint, suitable for `getaddrinfo`
    /// (IPv6 scope included).
    public var numericHost: String? {
        guard case let .hostPort(host, _) = self else { return nil }
        switch host {
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address):
            var text = "\(address)"
            if let interface = address.interface, !text.contains("%") { text += "%\(interface.name)" }
            return text
        case .name(let name, _): return name
        @unknown default: return nil
        }
    }
}
