import AnyRemoteNetwork
import AnyRemoteWire
import Foundation
import Network

/// Asks a paired Mac to update its AnyRemote, whatever protocol it speaks
/// (from protocol 20 on). The host downloads the latest release itself and
/// checks its signature, so all this proves is that we hold a key it accepts.
public enum RemoteUpdateRequest {
    public enum Failure: Error, LocalizedError, Equatable {
        /// The host refused or couldn't update (its words).
        case refused(String)
        /// The host is from before protocol 20, or didn't answer.
        case unsupported
        case connection(String)

        public var errorDescription: String? {
            switch self {
            case .refused(let reason): reason
            case .unsupported: "That Mac's AnyRemote can't be updated from another Mac."
            case .connection(let reason): reason
            }
        }
    }

    /// Returns the version the host is relaunching with. The host answers
    /// once it has downloaded and checked the update, which may take minutes.
    public static func send(to endpoint: NWEndpoint, credential: PairingCredential, viewerName: String,
                            timeout: TimeInterval = 600) async throws -> String {
        let queue = DispatchQueue(label: "anyremote.update-request")
        let parameters = ControlConnection.parameters(bulk: true)
        let control = ControlConnection(connection: NWConnection(to: endpoint, using: parameters),
                                        role: .viewer(credential: credential, viewerName: viewerName), queue: queue,
                                        purpose: .update)
        let once = Once<Result<String, Failure>>()
        return try await withCheckedThrowingContinuation { continuation in
            once.handler = { continuation.resume(with: $0) }
            control.onUpdateStarted = { version in once.fire(.success(version)) }
            control.onClose = { error in
                switch error {
                case nil: once.fire(.failure(.unsupported))
                case let error as ConnectionError:
                    switch error {
                    case .rejected(let reason) where reason.contains("can't be updated from another Mac"):
                        once.fire(.failure(.unsupported))
                    case .rejected(let reason): once.fire(.failure(.refused(reason)))
                    case .incompatible: once.fire(.failure(.unsupported))
                    default: once.fire(.failure(.connection(error.localizedDescription)))
                    }
                case let error?: once.fire(.failure(.connection(error.localizedDescription)))
                }
            }
            control.start()
            queue.asyncAfter(deadline: .now() + timeout) {
                once.fire(.failure(.connection(ConnectionError.timedOut.localizedDescription)))
                control.close()
            }
        }
    }
}

/// Delivers the first result only.
final class Once<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    var handler: ((Value) -> Void)?

    var hasFired: Bool { lock.withLock { fired } }

    func fire(_ value: Value) {
        lock.lock()
        guard !fired, let handler else { lock.unlock(); return }
        fired = true
        self.handler = nil
        lock.unlock()
        handler(value)
    }
}
