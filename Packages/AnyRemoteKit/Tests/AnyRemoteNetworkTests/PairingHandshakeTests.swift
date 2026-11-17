import AnyRemoteClient
import AnyRemoteHost
import AnyRemoteNetwork
import AnyRemoteWire
import Foundation
import Network
import Testing

/// Pairing with a six-digit code, end to end over 127.0.0.1, against the
/// real host service.
@Suite(.serialized, .timeLimit(.minutes(2))) @MainActor struct PairingHandshakeTests {
    /// What the host shows, as its UI would.
    @MainActor final class Screen {
        var prompts: [HostService.PairingPrompt] = []
        var ended: [(UInt32, Bool)] = []

        func code() async throws -> String {
            for _ in 0..<200 {
                if let prompt = prompts.last { return prompt.code }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw ConnectionError.timedOut
        }
    }

    struct Host {
        let service: HostService
        let store: HostSettingsStore
        let endpoint: NWEndpoint
        let screen: Screen
    }

    private func makeHost() async throws -> Host {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("anyremote-tests-\(UUID().uuidString)")
        setenv("ANYREMOTE_HOME", home.path, 1)
        let store = HostSettingsStore()
        let service = HostService(settings: store, options: .init(port: 0, advertise: false))
        let screen = Screen()
        service.onPairingRequest = { screen.prompts.append($0) }
        service.onPairingEnded = { screen.ended.append(($0, $1)) }
        try service.start()
        for _ in 0..<100 {
            if let port = service.port, port != 0 {
                return Host(service: service, store: store,
                            endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!), screen: screen)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ConnectionError.timedOut
    }

    /// A code other than the one shown.
    private func wrong(_ code: String) -> String { String(format: "%06d", (Int(code)! + 1) % 1_000_000) }

    /// Types the code shown on `host` (changed by `typo`), once it is shown.
    private func type(into pairing: HostPairingClient, from host: Host, typo: Bool = false) {
        Task {
            guard let code = try? await host.screen.code() else { return }
            pairing.submit(typo ? wrong(code) : code)
        }
    }

    @Test func pairsWithTheCodeShownAndConnectsWithTheNewKey() async throws {
        let host = try await makeHost()
        defer { host.service.stop() }
        let pairing = HostPairingClient(endpoint: host.endpoint, viewerName: "Viewer", viewerID: "viewer-id")
        pairing.onCodeShown = { name in
            #expect(name == ComputerName.current)
            type(into: pairing, from: host)
        }
        let paired = try await pairing.run()
        #expect(paired.hostID == host.store.settings.hostID)
        #expect(host.store.settings.viewers.map(\.name) == ["Viewer"])
        #expect(host.store.settings.viewers.first?.peerID == "viewer-id")
        #expect(host.store.settings.viewers.first?.id == paired.credential.id)

        let client = RemoteHostClient(endpoint: host.endpoint, credential: paired.credential, viewerName: "Viewer")
        _ = try await client.connect()
        client.disconnect()
        try await Task.sleep(for: .milliseconds(100))
        #expect(host.screen.ended.map(\.1) == [true])
    }

    @Test func aWrongCodeCanBeCorrected() async throws {
        let host = try await makeHost()
        defer { host.service.stop() }
        let pairing = HostPairingClient(endpoint: host.endpoint, viewerName: "Viewer", viewerID: "viewer-id")
        var rejections = 0
        pairing.onCodeShown = { _ in type(into: pairing, from: host, typo: true) }
        pairing.onCodeRejected = {
            rejections += 1
            type(into: pairing, from: host)
        }
        let paired = try await pairing.run()
        #expect(rejections == 1)
        #expect(host.store.settings.viewers.first?.id == paired.credential.id)
    }

    @Test func tooManyWrongCodesEndThePairing() async throws {
        let host = try await makeHost()
        defer { host.service.stop() }
        let pairing = HostPairingClient(endpoint: host.endpoint, viewerName: "Guesser", viewerID: "guesser")
        pairing.onCodeShown = { _ in type(into: pairing, from: host, typo: true) }
        pairing.onCodeRejected = { type(into: pairing, from: host, typo: true) }
        await #expect {
            try await pairing.run()
        } throws: { error in
            guard case HostPairingClient.Failure.refused(let reason) = error else { return false }
            return reason.contains("too many times")
        }
        #expect(host.store.settings.viewers.isEmpty)
    }

    @Test func pairingCanBeCancelledOnTheHost() async throws {
        let host = try await makeHost()
        defer { host.service.stop() }
        let pairing = HostPairingClient(endpoint: host.endpoint, viewerName: "Viewer", viewerID: "viewer-id")
        pairing.onCodeShown = { _ in
            Task {
                _ = try? await host.screen.code()
                host.service.cancelPairing(id: host.screen.prompts[0].id)
            }
        }
        await #expect {
            try await pairing.run()
        } throws: { error in
            guard case HostPairingClient.Failure.refused(let reason) = error else { return false }
            return reason.contains("cancelled")
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(host.screen.ended.map(\.1) == [false])
    }

    @Test func aRevokedKeyNoLongerConnects() async throws {
        let host = try await makeHost()
        defer { host.service.stop() }
        let pairing = HostPairingClient(endpoint: host.endpoint, viewerName: "Viewer", viewerID: "viewer-id")
        pairing.onCodeShown = { _ in type(into: pairing, from: host) }
        let paired = try await pairing.run()
        host.service.revokeViewer(id: paired.credential.id)
        let client = RemoteHostClient(endpoint: host.endpoint, credential: paired.credential, viewerName: "Viewer")
        await #expect {
            try await client.connect()
        } throws: { error in
            error.localizedDescription.contains("no longer paired")
        }
    }

    @Test func macsPairedWithTheLegacyCodeStillConnectUntilItIsRemoved() async throws {
        let host = try await makeHost()
        defer { host.service.stop() }
        let code = PairingCode.generate()
        host.store.update { $0.pairingCode = code.canonical }
        let client = RemoteHostClient(endpoint: host.endpoint, credential: .legacy(code), viewerName: "Old")
        _ = try await client.connect()
        client.disconnect()
        host.service.revokeViewer(id: nil)
        let again = RemoteHostClient(endpoint: host.endpoint, credential: .legacy(code), viewerName: "Old")
        await #expect(throws: (any Error).self) { try await again.connect() }
    }

    @Test func pairingAgainReplacesTheEarlierKey() async throws {
        let host = try await makeHost()
        defer { host.service.stop() }
        var keys: [PairingCredential] = []
        for _ in 0..<2 {
            host.screen.prompts.removeAll()
            let pairing = HostPairingClient(endpoint: host.endpoint, viewerName: "Viewer", viewerID: "viewer-id")
            pairing.onCodeShown = { _ in type(into: pairing, from: host) }
            keys.append(try await pairing.run().credential)
        }
        #expect(host.store.settings.viewers.map(\.id) == [keys[1].id])
    }

    @Test func sixDigitCodesNormalize() {
        #expect(PairingDigits.normalized("123 456") == "123456")
        #expect(PairingDigits.normalized("１２３４５６") == "123456")
        #expect(PairingDigits.normalized("12345") == nil)
        #expect(PairingDigits.normalized("12a456") == nil)
        #expect(PairingDigits.display("012345") == "012 345")
        #expect(PairingDigits.generate().count == 6)
    }
}
