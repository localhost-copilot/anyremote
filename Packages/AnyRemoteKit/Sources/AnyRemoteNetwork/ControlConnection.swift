import AnyRemoteWire
import CryptoKit
import Foundation
import Network
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Control")

public enum ConnectionError: Error, LocalizedError, Equatable {
    case handshake(String)
    case rejected(String)
    /// The other Mac speaks another protocol. `host` is which AnyRemote it
    /// runs; nil for Macs from before protocol 20, which don't say.
    case incompatible(host: AppVersionInfo?)
    case closed
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .handshake(let reason): "Handshake failed: \(reason)"
        case .rejected(let reason): reason
        case .incompatible: "The two Macs run incompatible AnyRemote versions."
        case .closed: "The connection was closed."
        case .timedOut: "The host did not respond."
        }
    }
}

/// What a host does with a paired Mac's request to update itself.
public enum RemoteUpdateOutcome: Sendable {
    /// The new version is downloaded and checked; the host relaunches with it.
    case started(version: String)
    case refused(reason: String)
}

/// Asked on the connection's queue; `reply` may be called from any thread,
/// possibly minutes later (after the download).
public typealias RemoteUpdateHandler = @Sendable (_ viewerName: String,
                                                  _ reply: @escaping @Sendable (RemoteUpdateOutcome) -> Void) -> Void

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
///
/// An update connection (`purpose: .update`) never gets keys: the host
/// answers its hello with a challenge whatever the protocol, the viewer
/// proves the pairing code over both nonces, and the host updates itself.
public final class ControlConnection: @unchecked Sendable {
    public enum Role: Sendable {
        case viewer(code: PairingCode, viewerName: String)
        case host(code: @Sendable () -> PairingCode?, hostID: String, hostName: String, sessionID: UInt32)
    }

    public let queue: DispatchQueue
    private let connection: NWConnection
    private let role: Role
    private let purpose: HandshakePurpose
    private let protocolVersion: UInt16

    // Queue-confined.
    private var parser = ControlFrameParser()
    private var sealer: StreamSealer?
    private var opener: StreamOpener?
    private var clientNonce: Data?
    private var authenticatedPeer = false
    private var closed = false
    private var updateNonces: (client: Data, server: Data)?
    private var updateViewerName = ""
    public private(set) var session: SecureSessionInfo?
    /// Which AnyRemote the host runs, once it said (viewer side).
    public private(set) var peerVersion: AppVersionInfo?

    /// Host side: this Mac's AnyRemote, told to viewers on other protocols.
    public var localVersion = AppVersionInfo(appVersion: AppVersionInfo.runningAppVersion, canUpdateRemotely: false)
    /// Host side: updates this Mac when a paired Mac asks. Without one,
    /// update requests are refused.
    public var updateHandler: RemoteUpdateHandler?
    /// Viewer side of an update connection: the host is relaunching with this version.
    public var onUpdateStarted: (@Sendable (String) -> Void)?

    /// Keys are ready (sealed messages may be sent). Viewer: after
    /// serverHello. Host: after the first sealed frame opened.
    public var onSecured: (@Sendable (SecureSessionInfo) -> Void)?
    public var onMessage: (@Sendable (ControlMessage) -> Void)?
    /// Raw sealed data (transfer chunks), on `queue`.
    public var onData: (@Sendable (Data) -> Void)?
    public var onClose: (@Sendable (Error?) -> Void)?

    public var remoteEndpoint: NWEndpoint? { connection.currentPath?.remoteEndpoint }

    /// `protocolVersion` is only overridden by tests.
    public init(connection: NWConnection, role: Role, queue: DispatchQueue, purpose: HandshakePurpose = .session,
                protocolVersion: UInt16 = anyRemoteProtocolVersion) {
        self.connection = connection
        self.role = role
        self.queue = queue
        self.purpose = purpose
        self.protocolVersion = protocolVersion
    }

    /// `bulk`: the transfer connection, which moves files rather than input.
    public static func parameters(bulk: Bool = false) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 8
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.serviceClass = bulk ? .bestEffort : .interactiveVideo
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
                    self.sendHandshake(.clientHello(version: self.protocolVersion, nonce: nonce,
                                                    viewerName: viewerName,
                                                    appVersion: AppVersionInfo.runningAppVersion,
                                                    purpose: self.purpose == .update ? .update : nil))
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

    /// Thread-safe. Seals raw data (a transfer chunk); `completion` runs on
    /// `queue` once the bytes are handed to the network, for flow control.
    public func send(data: Data, completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            guard !closed, var sealer else { completion?(); return }
            do {
                let body = try sealer.seal(data)
                self.sealer = sealer
                connection.send(content: ControlFrame.encode(kind: .sealedData, body: body),
                                completion: .contentProcessed { _ in completion?() })
            } catch {
                log.error("send failed: \(String(describing: error), privacy: .public)")
                completion?()
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
        case .sealedData:
            guard var opener else { throw ConnectionError.handshake("data before key exchange") }
            // The host takes data only once a message proved the viewer; on
            // the viewer, any frame that opens proves the host.
            if case .host = role, !authenticatedPeer { throw ConnectionError.handshake("data before authentication") }
            let plaintext = try opener.open(body)
            self.opener = opener
            authenticatedPeer = true
            onData?(plaintext)
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
        case let (.host(code, _, _, _), .clientHello(_, nonce, viewerName, _, .update?)):
            guard session == nil, updateNonces == nil else { throw ConnectionError.handshake("duplicate hello") }
            guard code() != nil else {
                refuse("Remote control is turned off on this Mac.", reason: "disabled")
                return
            }
            guard updateHandler != nil else {
                refuse("This Mac can't be updated from another Mac.", reason: "no updater", withVersion: true)
                return
            }
            let serverNonce = SessionKeys.randomNonce()
            updateNonces = (nonce, serverNonce)
            updateViewerName = viewerName
            sendHandshake(.updateChallenge(nonce: serverNonce, host: localVersion))
            // Nothing else may happen on this connection; don't keep it waiting.
            queue.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, !self.closed, !self.updateRequested else { return }
                self.finish(ConnectionError.timedOut)
            }

        case let (.host(code, _, _, _), .updateRequest(proof)):
            guard let nonces = updateNonces, !updateRequested, let code = code() else {
                throw ConnectionError.handshake("unexpected update request")
            }
            guard HMAC<SHA256>.isValidAuthenticationCode(
                proof, authenticating: Self.updateProofMessage(clientNonce: nonces.client, serverNonce: nonces.server),
                using: code.preSharedKey) else {
                log.notice("update request failed authentication")
                refuse("The pairing code is not valid for this Mac.", reason: "authentication failed")
                return
            }
            updateRequested = true
            log.notice("\(self.updateViewerName, privacy: .public) asked this Mac to update")
            updateHandler?(updateViewerName) { [weak self] outcome in
                guard let self else { return }
                self.queue.async {
                    guard !self.closed else { return }
                    switch outcome {
                    case .started(let version):
                        self.sendHandshake(.updateStarted(version: version), thenClose: true)
                        self.closed = true
                        self.onClose?(nil)
                    case .refused(let reason):
                        self.refuse(reason, reason: "update refused", withVersion: true)
                    }
                }
            }

        case let (.host(code, hostID, hostName, sessionID), .clientHello(version, nonce, viewerName, _, _)):
            guard session == nil else { throw ConnectionError.handshake("duplicate hello") }
            guard version == protocolVersion else {
                refuse("This Mac runs an incompatible AnyRemote version.", reason: "version \(version)",
                       withVersion: true)
                return
            }
            guard let code = code() else {
                refuse("Remote control is turned off on this Mac.", reason: "disabled")
                return
            }
            let serverNonce = SessionKeys.randomNonce()
            let keys = try SessionKeys(preSharedKey: code.preSharedKey, clientNonce: nonce, serverNonce: serverNonce)
            sealer = StreamSealer(key: keys.controlHostToViewer)
            opener = StreamOpener(key: keys.controlViewerToHost)
            session = SecureSessionInfo(sessionID: sessionID, keys: keys, peerID: "", peerName: viewerName)
            sendHandshake(.serverHello(version: protocolVersion, nonce: serverNonce,
                                       hostID: hostID, hostName: hostName, sessionID: sessionID))

        case let (.viewer(code, _), .updateChallenge(nonce, host)):
            guard purpose == .update, let clientNonce, updateNonces == nil else {
                throw ConnectionError.handshake("unexpected update challenge")
            }
            peerVersion = host
            updateNonces = (clientNonce, nonce)
            sendHandshake(.updateRequest(proof: Self.updateProof(key: code.preSharedKey, clientNonce: clientNonce,
                                                                 serverNonce: nonce)))

        case let (.viewer, .updateStarted(version)):
            guard purpose == .update, updateNonces != nil else { throw ConnectionError.handshake("unexpected update") }
            closed = true
            connection.cancel()
            onUpdateStarted?(version)
            onClose?(nil)

        case let (.viewer(code, _), .serverHello(version, nonce, hostID, hostName, sessionID)):
            guard session == nil, let clientNonce else { throw ConnectionError.handshake("unexpected hello") }
            guard version == protocolVersion else { throw ConnectionError.incompatible(host: nil) }
            // A host from before protocol 20 ignores an update hello and
            // answers as for a session: it can't update itself.
            guard purpose == .session else {
                throw ConnectionError.rejected("That Mac's AnyRemote can't be updated from another Mac.")
            }
            let keys = try SessionKeys(preSharedKey: code.preSharedKey, clientNonce: clientNonce, serverNonce: nonce)
            sealer = StreamSealer(key: keys.controlViewerToHost)
            opener = StreamOpener(key: keys.controlHostToViewer)
            let info = SecureSessionInfo(sessionID: sessionID, keys: keys, peerID: hostID, peerName: hostName)
            session = info
            onSecured?(info)

        case let (_, .failure(reason, host)):
            closed = true
            connection.cancel()
            if let host { peerVersion = host }
            // Only a refusal over versions turns into `incompatible`; hosts
            // from before protocol 20 say so in words alone.
            if purpose == .session, host.map({ $0.protocolVersion != protocolVersion })
                ?? reason.localizedCaseInsensitiveContains("incompatible AnyRemote version") {
                onClose?(ConnectionError.incompatible(host: host))
            } else {
                onClose?(ConnectionError.rejected(reason))
            }

        default:
            throw ConnectionError.handshake("unexpected handshake message")
        }
    }

    private var updateRequested = false

    /// Host side: answers with a failure and closes.
    private func refuse(_ message: String, reason: String, withVersion: Bool = false) {
        sendHandshake(.failure(reason: message, host: withVersion ? localVersion : nil), thenClose: true)
        closed = true
        onClose?(ConnectionError.handshake(reason))
    }

    /// Proves the pairing code for an update request, bound to both nonces.
    static func updateProof(key: SymmetricKey, clientNonce: Data, serverNonce: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: updateProofMessage(clientNonce: clientNonce, serverNonce: serverNonce),
                                             using: key))
    }

    private static func updateProofMessage(clientNonce: Data, serverNonce: Data) -> Data {
        var message = Data("anyremote update v1".utf8)
        message.append(clientNonce)
        message.append(serverNonce)
        return message
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
