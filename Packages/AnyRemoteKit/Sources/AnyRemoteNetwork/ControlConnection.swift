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
    /// The key the viewer used (`PairingCredential.id`; nil for the legacy code).
    public var credentialID: String? = nil
}

/// What a host has for the key a viewer names.
public enum CredentialLookup: Sendable {
    /// Remote control is off.
    case disabled
    /// No such key: never paired, or revoked.
    case unknown
    case found(PairingCredential)
}

/// A viewer asking to pair. `id` is the connection's session ID.
public struct PairingRequest: Sendable, Equatable {
    public let id: UInt32
    public let viewerName: String
    /// The viewer's own host ID, so pairing again replaces the earlier key.
    public let viewerID: String
}

/// How a host takes part in pairing, asked on the connection's queue.
public struct HostPairingHandler: Sendable {
    public enum Start: Sendable {
        /// Show these six digits.
        case show(String)
        case refuse(String)
    }

    public var begin: @Sendable (PairingRequest) -> Start
    /// The viewer proved the code: keep its key.
    public var complete: @Sendable (PairingRequest, PairingCredential) -> Void
    /// The code is no longer needed. `wrongCodes`: attempts that failed.
    public var end: @Sendable (PairingRequest, _ paired: Bool, _ wrongCodes: Int) -> Void

    public init(begin: @escaping @Sendable (PairingRequest) -> Start,
                complete: @escaping @Sendable (PairingRequest, PairingCredential) -> Void,
                end: @escaping @Sendable (PairingRequest, Bool, Int) -> Void) {
        self.begin = begin
        self.complete = complete
        self.end = end
    }
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
///
/// A pairing connection (`purpose: .pair`) never gets keys either: the host
/// shows six digits, the two sides run SPAKE2 with them (`pairingShare`,
/// `pairingReply`, `pairingConfirm`), and both derive the viewer's new key
/// from the result. A wrong code fails the host's confirmation on the viewer,
/// which may then try again, up to `maximumPairingAttempts` times.
public final class ControlConnection: @unchecked Sendable {
    public enum Role: Sendable {
        /// `credential` is nil only for pairing; `viewerID` is this Mac's
        /// own host ID, needed for pairing.
        case viewer(credential: PairingCredential?, viewerName: String, viewerID: String? = nil)
        /// `credentials` finds the key a viewer names (nil: the legacy code).
        case host(credentials: @Sendable (_ id: String?) -> CredentialLookup, hostID: String, hostName: String,
                  sessionID: UInt32)
    }

    public static let maximumPairingAttempts = 3
    /// How long the host shows a code.
    public static let pairingTimeout: TimeInterval = 180
    /// Identifies this protocol's pairing in the SPAKE2 key schedule.
    static let pairingContext = Data("anyremote pairing v1".utf8)

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
    private var hostPairing: HostPairingState?
    private var viewerPairing: ViewerPairingState?

    private struct HostPairingState {
        let request: PairingRequest
        let code: String
        let hostID: String
        var attempts = 0
        /// The latest attempt: its keys and the ID of the key it would make.
        var pending: (result: SPAKE2.Result, credentialID: String)?
        var paired = false
    }

    private struct ViewerPairingState {
        let hostID: String
        let hostName: String
        var attempt: SPAKE2?
        var credential: PairingCredential?
    }
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
    /// Host side: shows pairing codes and keeps the keys pairing makes.
    /// Without one, pairing is refused.
    public var pairingHandler: HostPairingHandler?
    /// Viewer side of a pairing connection: the host shows a code now.
    public var onPairingStarted: (@Sendable (_ hostID: String, _ hostName: String) -> Void)?
    /// The code given was wrong; another may be given.
    public var onPairingCodeRejected: (@Sendable () -> Void)?
    /// Paired: the new key, then the connection closes.
    public var onPaired: (@Sendable (PairingCredential, _ hostID: String, _ hostName: String) -> Void)?

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
                if case let .viewer(credential, viewerName, viewerID) = self.role {
                    let nonce = SessionKeys.randomNonce()
                    self.clientNonce = nonce
                    self.sendHandshake(.clientHello(version: self.protocolVersion, nonce: nonce,
                                                    viewerName: viewerName,
                                                    appVersion: AppVersionInfo.runningAppVersion,
                                                    purpose: self.purpose == .session ? nil : self.purpose,
                                                    credentialID: credential?.id,
                                                    viewerID: self.purpose == .pair ? viewerID : nil))
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
        case let (.host(credentials, _, _, _), .clientHello(_, nonce, viewerName, _, .update?, credentialID, _)):
            guard session == nil, updateNonces == nil else { throw ConnectionError.handshake("duplicate hello") }
            if case .disabled = credentials(credentialID) {
                refuse("Remote control is turned off on this Mac.", reason: "disabled")
                return
            }
            updateCredentialID = credentialID
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

        case let (.host(credentials, _, _, _), .updateRequest(proof)):
            guard let nonces = updateNonces, !updateRequested else {
                throw ConnectionError.handshake("unexpected update request")
            }
            guard case .found(let credential) = credentials(updateCredentialID),
                  HMAC<SHA256>.isValidAuthenticationCode(
                proof, authenticating: Self.updateProofMessage(clientNonce: nonces.client, serverNonce: nonces.server),
                using: credential.preSharedKey) else {
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

        case let (.host(credentials, hostID, hostName, sessionID),
                  .clientHello(version, _, viewerName, _, .pair?, _, viewerID)):
            guard session == nil, hostPairing == nil else { throw ConnectionError.handshake("duplicate hello") }
            guard version == protocolVersion else {
                refuse("This Mac runs an incompatible AnyRemote version.", reason: "version \(version)",
                       withVersion: true)
                return
            }
            if case .disabled = credentials(nil) {
                refuse("Remote control is turned off on this Mac.", reason: "disabled")
                return
            }
            guard let handler = pairingHandler else {
                refuse("This Mac can’t be paired with right now.", reason: "no pairing")
                return
            }
            let request = PairingRequest(id: sessionID, viewerName: viewerName, viewerID: viewerID ?? "")
            switch handler.begin(request) {
            case .refuse(let reason):
                refuse(reason, reason: "pairing refused")
            case .show(let code):
                log.notice("\(viewerName, privacy: .public) asked to pair")
                hostPairing = HostPairingState(request: request, code: code, hostID: hostID)
                sendHandshake(.pairingStarted(hostID: hostID, hostName: hostName))
                queue.asyncAfter(deadline: .now() + Self.pairingTimeout) { [weak self] in
                    guard let self, !self.closed, self.hostPairing?.paired == false else { return }
                    self.refuse("The pairing code expired. Start pairing again for a new one.", reason: "pairing timed out")
                }
            }

        case (.host, .pairingShare(let share)):
            guard var state = hostPairing, !state.paired else { throw ConnectionError.handshake("unexpected share") }
            state.attempts += 1
            hostPairing = state
            guard state.attempts <= Self.maximumPairingAttempts else {
                refuse("The pairing code was wrong too many times. Start pairing again for a new one.",
                       reason: "too many attempts")
                return
            }
            let attempt = SPAKE2(role: .b, identityA: Data(state.request.viewerID.utf8), identityB: Data(state.hostID.utf8),
                                 password: PairingDigits.passwordScalar(state.code),
                                 additionalData: Self.pairingContext)
            let result: SPAKE2.Result
            do { result = try attempt.finish(peerShare: share) } catch {
                refuse("Pairing failed.", reason: "invalid share")
                return
            }
            let credentialID = UUID().uuidString
            state.pending = (result, credentialID)
            hostPairing = state
            sendHandshake(.pairingReply(share: attempt.share, confirmation: result.confirmation, credentialID: credentialID))

        case (.host, .pairingConfirm(let confirmation)):
            guard var state = hostPairing, !state.paired, let pending = state.pending else {
                throw ConnectionError.handshake("unexpected confirmation")
            }
            // The viewer only confirms once ours checked out, so a mismatch
            // here isn't a typo: someone is in between. Give up.
            guard pending.result.verify(peerConfirmation: confirmation) else {
                log.notice("pairing confirmation from \(state.request.viewerName, privacy: .public) failed")
                refuse("Pairing failed.", reason: "confirmation failed")
                return
            }
            state.paired = true
            hostPairing = state
            let credential = PairingCredential.derived(fromPairingSecret: pending.result.sharedKey, id: pending.credentialID)
            log.notice("paired with \(state.request.viewerName, privacy: .public)")
            pairingHandler?.complete(state.request, credential)
            sendHandshake(.pairingDone, thenClose: true)
            closed = true
            endPairing()
            onClose?(nil)

        case let (.host(credentials, hostID, hostName, sessionID),
                  .clientHello(version, nonce, viewerName, _, _, credentialID, _)):
            guard session == nil else { throw ConnectionError.handshake("duplicate hello") }
            guard version == protocolVersion else {
                refuse("This Mac runs an incompatible AnyRemote version.", reason: "version \(version)",
                       withVersion: true)
                return
            }
            let credential: PairingCredential
            switch credentials(credentialID) {
            case .disabled:
                refuse("Remote control is turned off on this Mac.", reason: "disabled")
                return
            case .unknown:
                refuse("This Mac is no longer paired with that Mac. Pair them again.", reason: "unknown credential")
                return
            case .found(let found):
                credential = found
            }
            let serverNonce = SessionKeys.randomNonce()
            let keys = try SessionKeys(preSharedKey: credential.preSharedKey, clientNonce: nonce, serverNonce: serverNonce)
            sealer = StreamSealer(key: keys.controlHostToViewer)
            opener = StreamOpener(key: keys.controlViewerToHost)
            session = SecureSessionInfo(sessionID: sessionID, keys: keys, peerID: "", peerName: viewerName,
                                        credentialID: credentialID)
            sendHandshake(.serverHello(version: protocolVersion, nonce: serverNonce,
                                       hostID: hostID, hostName: hostName, sessionID: sessionID))

        case let (.viewer(credential?, _, _), .updateChallenge(nonce, host)):
            guard purpose == .update, let clientNonce, updateNonces == nil else {
                throw ConnectionError.handshake("unexpected update challenge")
            }
            peerVersion = host
            updateNonces = (clientNonce, nonce)
            sendHandshake(.updateRequest(proof: Self.updateProof(key: credential.preSharedKey, clientNonce: clientNonce,
                                                                 serverNonce: nonce)))

        case let (.viewer, .pairingStarted(hostID, hostName)):
            guard purpose == .pair, viewerPairing == nil else { throw ConnectionError.handshake("unexpected pairing") }
            viewerPairing = ViewerPairingState(hostID: hostID, hostName: hostName)
            onPairingStarted?(hostID, hostName)

        case let (.viewer, .pairingReply(share, confirmation, credentialID)):
            guard var state = viewerPairing, let attempt = state.attempt else {
                throw ConnectionError.handshake("unexpected pairing reply")
            }
            state.attempt = nil
            let result = try attempt.finish(peerShare: share)
            guard result.verify(peerConfirmation: confirmation) else {
                viewerPairing = state
                onPairingCodeRejected?()
                return
            }
            state.credential = PairingCredential.derived(fromPairingSecret: result.sharedKey, id: credentialID)
            viewerPairing = state
            sendHandshake(.pairingConfirm(result.confirmation))

        case (.viewer, .pairingDone):
            guard let state = viewerPairing, let credential = state.credential else {
                throw ConnectionError.handshake("unexpected pairing result")
            }
            closed = true
            connection.cancel()
            onPaired?(credential, state.hostID, state.hostName)
            onClose?(nil)

        case let (.viewer, .updateStarted(version)):
            guard purpose == .update, updateNonces != nil else { throw ConnectionError.handshake("unexpected update") }
            closed = true
            connection.cancel()
            onUpdateStarted?(version)
            onClose?(nil)

        case let (.viewer(credential?, _, _), .serverHello(version, nonce, hostID, hostName, sessionID)):
            guard session == nil, let clientNonce else { throw ConnectionError.handshake("unexpected hello") }
            guard version == protocolVersion else { throw ConnectionError.incompatible(host: nil) }
            // A host from before protocol 20 ignores an update hello and
            // answers as for a session: it can't update itself.
            guard purpose == .session else {
                throw ConnectionError.rejected("That Mac's AnyRemote can't be updated from another Mac.")
            }
            let keys = try SessionKeys(preSharedKey: credential.preSharedKey, clientNonce: clientNonce, serverNonce: nonce)
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
    private var updateCredentialID: String?

    /// Viewer side of a pairing connection: the digits shown on the host.
    /// Thread-safe; again after `onPairingCodeRejected`.
    public func submitPairingCode(_ digits: String) {
        queue.async { [self] in
            guard !closed, case let .viewer(_, _, viewerID) = role, var state = viewerPairing,
                  state.credential == nil else { return }
            let attempt = SPAKE2(role: .a, identityA: Data((viewerID ?? "").utf8), identityB: Data(state.hostID.utf8),
                                 password: PairingDigits.passwordScalar(digits), additionalData: Self.pairingContext)
            state.attempt = attempt
            viewerPairing = state
            sendHandshake(.pairingShare(attempt.share))
        }
    }

    /// Host side: stops a pairing under way (the user cancelled it here).
    public func cancelPairing(reason: String) {
        queue.async { [self] in
            guard !closed, hostPairing != nil else { return }
            refuse(reason, reason: "pairing cancelled")
        }
    }

    /// Host side: the code shown for this connection is no longer needed.
    private func endPairing() {
        guard let state = hostPairing else { return }
        hostPairing = nil
        let wrong = state.attempts - (state.paired ? 1 : 0)
        pairingHandler?.end(state.request, state.paired, max(0, wrong))
    }

    /// Host side: answers with a failure and closes.
    private func refuse(_ message: String, reason: String, withVersion: Bool = false) {
        sendHandshake(.failure(reason: message, host: withVersion ? localVersion : nil), thenClose: true)
        closed = true
        endPairing()
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
        endPairing()
        connection.cancel()
        onClose?(error)
    }
}
