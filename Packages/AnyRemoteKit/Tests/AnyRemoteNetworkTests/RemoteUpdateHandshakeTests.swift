import AnyRemoteClient
import AnyRemoteNetwork
import AnyRemoteWire
import Foundation
import Network
import Testing

/// Version reporting and remote update requests over real connections on 127.0.0.1.
@Suite(.serialized, .timeLimit(.minutes(2))) struct RemoteUpdateHandshakeTests {
    final class Host: @unchecked Sendable {
        let listener: ControlListener
        let code = PairingCode.generate()
        private let lock = NSLock()
        private var requesters: [String] = []
        private var connections: [ControlConnection] = []

        /// `outcome` nil: the host has no updater.
        init(protocolVersion: UInt16 = anyRemoteProtocolVersion, outcome: RemoteUpdateOutcome?) throws {
            let queue = DispatchQueue(label: "test.update-host")
            listener = try ControlListener(port: 0, serviceName: nil, hostID: "test", queue: queue)
            let ready = DispatchSemaphore(value: 0)
            listener.onStateChange = { if case .ready = $0 { ready.signal() } }
            let code = code
            listener.onConnection = { [self] connection in
                let control = ControlConnection(connection: connection,
                                                role: .host(code: { code }, hostID: "test", hostName: "Host", sessionID: 1),
                                                queue: queue, protocolVersion: protocolVersion)
                control.localVersion = AppVersionInfo(appVersion: "0.26.0", protocolVersion: protocolVersion,
                                                      canUpdateRemotely: outcome != nil)
                if let outcome {
                    control.updateHandler = { [self] name, reply in
                        lock.withLock { requesters.append(name) }
                        reply(outcome)
                    }
                }
                lock.withLock { connections.append(control) }
                control.start()
            }
            listener.start()
            // A listener that never gets ready (a CI machine refusing local
            // connections) fails the test instead of hanging the run.
            guard ready.wait(timeout: .now() + 10) == .success else { throw ListenerNotReady() }
        }

        var endpoint: NWEndpoint { .hostPort(host: "127.0.0.1", port: .init(rawValue: listener.port!)!) }
        var askedBy: [String] { lock.withLock { requesters } }
        deinit { listener.cancel() }
    }

    @Test func pairedMacCanAskForAnUpdateWhateverItsProtocol() async throws {
        let host = try Host(protocolVersion: anyRemoteProtocolVersion + 1, outcome: .started(version: "0.27.0"))
        let version = try await RemoteUpdateRequest.send(to: host.endpoint, code: host.code, viewerName: "Viewer")
        #expect(version == "0.27.0")
        #expect(host.askedBy == ["Viewer"])
    }

    @Test func wrongCodeCantAskForAnUpdate() async throws {
        let host = try Host(outcome: .started(version: "0.27.0"))
        await #expect(throws: RemoteUpdateRequest.Failure.self) {
            try await RemoteUpdateRequest.send(to: host.endpoint, code: .generate(), viewerName: "Viewer")
        }
        #expect(host.askedBy.isEmpty)
    }

    @Test func hostWithoutUpdaterOrWithRefusalSaysSo() async throws {
        let plain = try Host(outcome: nil)
        await #expect(throws: RemoteUpdateRequest.Failure.unsupported) {
            try await RemoteUpdateRequest.send(to: plain.endpoint, code: plain.code, viewerName: "Viewer")
        }
        let refusing = try Host(outcome: .refused(reason: "Already up to date."))
        await #expect(throws: RemoteUpdateRequest.Failure.refused("Already up to date.")) {
            try await RemoteUpdateRequest.send(to: refusing.endpoint, code: refusing.code, viewerName: "Viewer")
        }
    }

    @Test func sessionOnAnotherProtocolLearnsTheHostsVersion() async throws {
        let host = try Host(protocolVersion: anyRemoteProtocolVersion + 1, outcome: .started(version: "0.27.0"))
        let control = ControlConnection(connection: NWConnection(to: host.endpoint, using: ControlConnection.parameters()),
                                        role: .viewer(code: host.code, viewerName: "Viewer"),
                                        queue: DispatchQueue(label: "test.viewer"))
        let error: ConnectionError? = await withCheckedContinuation { continuation in
            control.onClose = { continuation.resume(returning: $0 as? ConnectionError) }
            control.start()
        }
        let expected = AppVersionInfo(appVersion: "0.26.0", protocolVersion: anyRemoteProtocolVersion + 1,
                                      canUpdateRemotely: true)
        #expect(error == .incompatible(host: expected))
        #expect(host.askedBy.isEmpty)
    }

    /// A host from before protocol 20 sends an older failure: no version, its
    /// words only. It must still read as incompatible, and old hellos must
    /// decode in both directions.
    @Test func handshakeStaysReadableAcrossVersions() throws {
        let old = Data(#"{"failure":{"reason":"This Mac runs an incompatible AnyRemote version."}}"#.utf8)
        #expect(try ControlCoding.decode(HandshakeMessage.self, from: old)
            == .failure(reason: "This Mac runs an incompatible AnyRemote version.", host: nil))
        let oldHello = Data(#"{"clientHello":{"version":19,"nonce":"AAAA","viewerName":"Old"}}"#.utf8)
        #expect(try ControlCoding.decode(HandshakeMessage.self, from: oldHello)
            == .clientHello(version: 19, nonce: Data([0, 0, 0]), viewerName: "Old", appVersion: nil, purpose: nil))
        // What an old Mac would decode: the same keys, with extras it ignores.
        let hello = try ControlCoding.encode(HandshakeMessage.clientHello(
            version: 20, nonce: Data([1]), viewerName: "New", appVersion: "0.26.0", purpose: .update))
        let object = try JSONSerialization.jsonObject(with: hello) as? [String: [String: Any]]
        #expect(Set(object?["clientHello"]?.keys ?? [:].keys)
            == ["version", "nonce", "viewerName", "appVersion", "purpose"])
    }
}

struct ListenerNotReady: Error {}
