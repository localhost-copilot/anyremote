import AnyRemoteWire
import CryptoKit
import Foundation
import Network
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Control")

public enum ConnectionError: Error, LocalizedError, Equatable {
    case handshake(String)
    case rejected(String)
    case closed
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .handshake(let reason): "Handshake failed: \(reason)"
        case .rejected(let reason): reason
        case .closed: "The connection was closed."
        case .timedOut: "The host did not respond."
        }
    }
}

/// Result of a completed key exchange.
public struct SecureSessionInfo: Sendable {
    public let sessionID: UInt32
    public let keys: SessionKeys
    /// Host identity (viewer side) or viewer name (host side).
    public let peerID: String
    public let peerName: String
}

/// Sealed control channel over TCP.
///
/// Handshake: the viewer sends `clientHello` (nonce), the host answers with
/// `serverHello` (nonce, session ID); both derive `SessionKeys` from the
/// pairing secret. Every later frame is sealed. The host learns that the
/// viewer holds the secret when the first sealed frame opens; the viewer
/// learns the same about the host from the first sealed reply.
public final class ControlConnection: @unchecked Sendable {
    public enum Role: Sendable {
        case viewer(code: PairingCode, viewerName: String)
        case host(code: @Sendable () -> PairingCode?, hostID: String, hostName: String, sessionID: UInt32)
    }

    public let queue: DispatchQueue
    private let connection: NWConnection
    private let role: Role

    // Queue-confined.
    private var parser = ControlFrameParser()
    private var sealer: StreamSealer?
    private var opener: StreamOpener?
    private var clientNonce: Data?
    private var authenticatedPeer = false
    private var closed = false
    public private(set) var session: SecureSessionInfo?

    /// Keys are ready (sealed messages may be sent). Viewer: after
    /// serverHello. Host: after the first sealed frame opened.
    public var onSecured: (@Sendable (SecureSessionInfo) -> Void)?
    public var onMessage: (@Sendable (ControlMessage) -> Void)?
    public var onClose: (@Sendable (Error?) -> Void)?

    public var remoteEndpoint: NWEndpoint? { connection.currentPath?.remoteEndpoint }

    public init(connection: NWConnection, role: Role, queue: DispatchQueue) {
        self.connection = connection
        self.role = role
        self.queue = queue
    }

    public static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 8
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.serviceClass = .interactiveVideo
        parameters.includePeerToPeer = true
        return parameters
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if case .viewer(_, let viewerName) = self.role {
                    let nonce = SessionKeys.randomNonce()
                    self.clientNonce = nonce
                    self.sendHandshake(.clientHello(version: anyRemoteProtocolVersion, nonce: nonce,
                                                    viewerName: viewerName))
                }
                self.receive()
            case .failed(let error):
                self.finish(error)
            case .waiting(let error):
                // Refused or unreachable: report instead of waiting forever.
                self.finish(error)
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Thread-safe.
    public func send(_ message: ControlMessage) {
        queue.async { [self] in
            guard !closed, var sealer else { return }
            do {
                let body = try sealer.seal(try ControlCoding.encode(message))
                self.sealer = sealer
                connection.send(content: ControlFrame.encode(kind: .sealed, body: body),
                                completion: .contentProcessed { _ in })
            } catch {
                log.error("send failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Thread-safe. Sends a final message, then closes.
    public func close(after message: ControlMessage? = nil) {
        queue.async { [self] in
            guard !closed else { return }
            if let message, var sealer, let body = try? sealer.seal(try ControlCoding.encode(message)) {
                self.sealer = sealer
                connection.send(content: ControlFrame.encode(kind: .sealed, body: body),
                                completion: .contentProcessed { [weak self] _ in self?.connection.cancel() })
            } else {
                connection.cancel()
            }
        }
    }

    private func sendHandshake(_ message: HandshakeMessage, thenClose: Bool = false) {
        guard let body = try? ControlCoding.encode(message) else { return }
        connection.send(content: ControlFrame.encode(kind: .handshake, body: body),
                        completion: .contentProcessed { [weak self] _ in
                            if thenClose { self?.connection.cancel() }
                        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    for (kind, body) in try self.parser.append(data) {
                        try self.handle(kind: kind, body: body)
                        if self.closed { return }
                    }
                } catch {
                    self.fail(error)
                    return
                }
            }
            if let error {
                self.finish(error)
            } else if isComplete {
                self.finish(nil)
            } else {
                self.receive()
            }
        }
    }

    private func handle(kind: ControlFrame.Kind, body: Data) throws {
        switch kind {
        case .handshake:
            try handleHandshake(try ControlCoding.decode(HandshakeMessage.self, from: body))
        case .sealed:
            guard var opener else { throw ConnectionError.handshake("sealed frame before key exchange") }
            let plaintext: Data
            do {
                plaintext = try opener.open(body)
            } catch {
                if case .host = role, !authenticatedPeer {
                    log.notice("viewer failed authentication")
                    sendHandshake(.failure(reason: "The pairing code is not valid for this Mac."), thenClose: true)
                    closed = true
                    onClose?(ConnectionError.handshake("authentication failed"))
                    return
                }
                throw error
            }
            self.opener = opener
            if !authenticatedPeer {
                authenticatedPeer = true
                if case .host = role, let session { onSecured?(session) }
            }
            onMessage?(try ControlCoding.decode(ControlMessage.self, from: plaintext))
        }
    }

    private func handleHandshake(_ message: HandshakeMessage) throws {
        switch (role, message) {
        case let (.host(code, hostID, hostName, sessionID), .clientHello(version, nonce, viewerName)):
            guard session == nil else { throw ConnectionError.handshake("duplicate hello") }
            guard version == anyRemoteProtocolVersion else {
                sendHandshake(.failure(reason: "This Mac runs an incompatible AnyRemote version."), thenClose: true)
                closed = true
                onClose?(ConnectionError.handshake("version \(version)"))
                return
            }
            guard let code = code() else {
                sendHandshake(.failure(reason: "Remote control is turned off on this Mac."), thenClose: true)
                closed = true
                onClose?(ConnectionError.handshake("disabled"))
                return
            }
            let serverNonce = SessionKeys.randomNonce()
            let keys = try SessionKeys(preSharedKey: code.preSharedKey, clientNonce: nonce, serverNonce: serverNonce)
            sealer = StreamSealer(key: keys.controlHostToViewer)
            opener = StreamOpener(key: keys.controlViewerToHost)
            session = SecureSessionInfo(sessionID: sessionID, keys: keys, peerID: "", peerName: viewerName)
            sendHandshake(.serverHello(version: anyRemoteProtocolVersion, nonce: serverNonce,
                                       hostID: hostID, hostName: hostName, sessionID: sessionID))

        case let (.viewer(code, _), .serverHello(version, nonce, hostID, hostName, sessionID)):
            guard session == nil, let clientNonce else { throw ConnectionError.handshake("unexpected hello") }
            guard version == anyRemoteProtocolVersion else {
                throw ConnectionError.handshake("The host runs an incompatible AnyRemote version.")
            }
            let keys = try SessionKeys(preSharedKey: code.preSharedKey, clientNonce: clientNonce, serverNonce: nonce)
            sealer = StreamSealer(key: keys.controlViewerToHost)
            opener = StreamOpener(key: keys.controlHostToViewer)
            let info = SecureSessionInfo(sessionID: sessionID, keys: keys, peerID: hostID, peerName: hostName)
            session = info
            onSecured?(info)

        case let (_, .failure(reason)):
            closed = true
            connection.cancel()
            onClose?(ConnectionError.rejected(reason))

        default:
            throw ConnectionError.handshake("unexpected handshake message")
        }
    }

    private func fail(_ error: Error) {
        log.error("control connection failed: \(String(describing: error), privacy: .public)")
        connection.cancel()
        finish(error)
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?(error)
    }
}
