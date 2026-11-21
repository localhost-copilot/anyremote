import AnyRemoteNetwork
import AnyRemoteWire
import Foundation
import Network

/// Pairs with a Mac: it shows six digits, the user types them here, and
/// both Macs end up with a key for this Mac alone (see `ControlConnection`).
///
/// The callbacks run on the main queue. A wrong code calls
/// `onCodeRejected`; `submit` may then be called again, until the host
/// gives up (`ControlConnection.maximumPairingAttempts`).
public final class HostPairingClient: @unchecked Sendable {
    public struct Paired: Sendable {
        public let credential: PairingCredential
        public let hostID: String
        public let hostName: String
    }

    public enum Failure: Error, LocalizedError, Equatable {
        /// The host refused or gave up (its words).
        case refused(String)
        /// The host's AnyRemote is too old to pair this way.
        case unsupported
        case connection(String)

        public var errorDescription: String? {
            switch self {
            case .refused(let reason): reason
            case .unsupported: "That Mac runs an AnyRemote version that pairs differently."
            case .connection(let reason): reason
            }
        }
    }

    /// The host shows a code now.
    public var onCodeShown: (@MainActor @Sendable (_ hostName: String) -> Void)?
    public var onCodeRejected: (@MainActor @Sendable () -> Void)?

    private let control: ControlConnection
    private let queue = DispatchQueue(label: "anyremote.pairing")
    private let once = Once<Result<Paired, Failure>>()
    private let started = Once<Void>()

    public init(route: HostRoute, viewerName: String, viewerID: String) {
        control = ControlConnection(transport: route.makeStream(),
                                    role: .viewer(credential: nil, viewerName: viewerName, viewerID: viewerID),
                                    queue: queue, purpose: .pair)
    }

    public convenience init(endpoint: NWEndpoint, viewerName: String, viewerID: String) {
        self.init(route: .network(endpoint), viewerName: viewerName, viewerID: viewerID)
    }

    /// Asks the host to show a code, and waits until pairing succeeds or fails.
    public func run() async throws -> Paired {
        try await withCheckedThrowingContinuation { continuation in
            once.handler = { continuation.resume(with: $0) }
            started.handler = { _ in }
            control.onPairingStarted = { [weak self] _, hostName in
                self?.started.fire(())
                let callback = self?.onCodeShown
                DispatchQueue.main.async { callback?(hostName) }
            }
            control.onPairingCodeRejected = { [weak self] in
                let callback = self?.onCodeRejected
                DispatchQueue.main.async { callback?() }
            }
            control.onPaired = { [weak self] credential, hostID, hostName in
                self?.once.fire(.success(Paired(credential: credential, hostID: hostID, hostName: hostName)))
            }
            control.onClose = { [weak self] error in
                guard let self else { return }
                // A host that closes before showing a code didn't understand
                // the request: an AnyRemote from before protocol 24.
                let unanswered = !self.started.hasFired
                switch error {
                case let ConnectionError.rejected(reason)?: self.once.fire(.failure(.refused(reason)))
                case ConnectionError.incompatible?: self.once.fire(.failure(.unsupported))
                case nil where unanswered: self.once.fire(.failure(.unsupported))
                case nil: self.once.fire(.failure(.connection(ConnectionError.closed.localizedDescription)))
                case let error?:
                    self.once.fire(.failure(unanswered && !(error is NWError) ? .unsupported
                                            : .connection(error.localizedDescription)))
                }
            }
            control.start()
        }
    }

    /// The six digits shown on the host.
    public func submit(_ digits: String) { control.submitPairingCode(digits) }

    public func cancel() { control.close() }
}
