import AnyRemoteClient
import AnyRemoteHost
import AnyRemoteNetwork
import AnyRemoteWire
import Foundation
import Network
import Testing

/// End-to-end handshake and session admission over 127.0.0.1.
@Suite(.serialized) struct LoopbackSessionTests {
    private static func makeHost() throws -> (HostService, PairingCredential) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("anyremote-tests-\(UUID().uuidString)")
        setenv("ANYREMOTE_HOME", home.path, 1)
        let store = HostSettingsStore()
        let service = HostService(settings: store, options: .init(port: 0, advertise: false))
        try service.start()
        return (service, store.loopbackCredential)
    }

    private static func endpoint(_ service: HostService) async throws -> NWEndpoint {
        for _ in 0..<100 {
            if let port = service.port, port != 0 {
                return .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ConnectionError.timedOut
    }

    @Test func pairedViewerConnectsAndSyncsClock() async throws {
        let (service, code) = try Self.makeHost()
        defer { service.stop() }
        let client = RemoteHostClient(endpoint: try await Self.endpoint(service), credential: code, viewerName: "test")
        let welcome = try await client.connect()
        #expect(welcome.datagramPort != 0)
        #expect(!welcome.hostID.isEmpty)
        try await Task.sleep(for: .milliseconds(400))
        // Same machine: the estimated offset must be ~0.
        let now = UInt64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        let mapped = client.clock.localTime(fromSender: now)
        #expect(mapped != nil)
        if let mapped { #expect(abs(Int64(bitPattern: mapped &- now)) < 2_000_000) }
        #expect((client.roundTripMilliseconds ?? 99) < 20)
        client.disconnect()
    }

    /// A viewer reaching the host through the embedded tailnet node: the
    /// control connection, the clock, the transfer connection and the
    /// keepalives all go through the node's sockets, and the host answers
    /// on the node's datagram port.
    @Test func viewerConnectsThroughTheTailnet() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("anyremote-tests-\(UUID().uuidString)")
        setenv("ANYREMOTE_HOME", home.path, 1)
        let store = HostSettingsStore()
        let service = HostService(settings: store, options: .init(port: 0, advertise: false))
        let tailnet = FakeTailnet()
        service.setTailnet(tailnet)
        try service.start()
        defer { service.stop() }
        let client = RemoteHostClient(route: .tailnet(tailnet, host: tailnet.address, port: 0),
                                      credential: store.loopbackCredential, viewerName: "tailnet viewer")
        let welcome = try await client.connect()
        #expect(welcome.datagramPort >= 50_000)
        #expect(welcome.tailnetAddresses?.first == tailnet.address)
        #expect(service.currentStatus.viewers.map(\.name) == ["tailnet viewer"])
        for _ in 0..<50 where tailnet.delivered(to: welcome.datagramPort) == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(tailnet.delivered(to: welcome.datagramPort) > 0)
        try await Task.sleep(for: .milliseconds(300))
        #expect((client.roundTripMilliseconds ?? 99) < 20)
        client.disconnect()
        try await Task.sleep(for: .milliseconds(200))
        #expect(service.currentStatus.viewers.isEmpty)
    }

    /// A paired Mac found at a new address is recognized by its key, without
    /// a session: the host lists no viewer meanwhile.
    @Test func identityProbeRecognizesTheKeysMacOnly() async throws {
        let (service, code) = try Self.makeHost()
        defer { service.stop() }
        let route = HostRoute.network(try await Self.endpoint(service))
        let id = await HostIdentityProbe.hostID(at: route, credential: code, viewerName: "probe")
        #expect(id == service.settingsStore.settings.hostID)
        #expect(service.currentStatus.viewers.isEmpty)
        #expect(await HostIdentityProbe.hostID(at: route, credential: .generate(), viewerName: "probe") == nil)
    }

    /// The first way that answers wins, and an earlier one beats a later one.
    @Test func routeProbePrefersTheFirstThatAnswers() async throws {
        let (service, _) = try Self.makeHost()
        defer { service.stop() }
        let host = HostRoute.network(try await Self.endpoint(service))
        let closed = HostRoute.network(.hostPort(host: "127.0.0.1", port: 9))
        #expect(await RouteProbe.preferred([closed, host]) == 1)
        #expect(await RouteProbe.preferred([host, host]) == 0)
        #expect(await RouteProbe.preferred([closed, closed], timeout: 1) == nil)
    }

    @Test func wrongCodeIsRejected() async throws {
        let (service, _) = try Self.makeHost()
        defer { service.stop() }
        let client = RemoteHostClient(endpoint: try await Self.endpoint(service),
                                      credential: .generate(), viewerName: "intruder")
        await #expect(throws: (any Error).self) { try await client.connect() }
    }

    @Test func viewersShareUntilFull() async throws {
        let (service, code) = try Self.makeHost()
        defer { service.stop() }
        let endpoint = try await Self.endpoint(service)
        var clients: [RemoteHostClient] = []
        for index in 0..<HostService.maximumViewers {
            let client = RemoteHostClient(endpoint: endpoint, credential: code, viewerName: "viewer\(index)")
            _ = try await client.connect()
            clients.append(client)
        }
        #expect(service.currentStatus.viewers.map(\.name) == (0..<HostService.maximumViewers).map { "viewer\($0)" })
        let extra = RemoteHostClient(endpoint: endpoint, credential: code, viewerName: "extra")
        do {
            _ = try await extra.connect()
            Issue.record("a viewer beyond the limit was admitted")
        } catch {
            #expect(error.localizedDescription.contains("viewer0"))
        }
        // Taking over ends the longest-connected session.
        let late = RemoteHostClient(endpoint: endpoint, credential: code, viewerName: "late")
        _ = try await late.connect(takeOver: true)
        try await Task.sleep(for: .milliseconds(200))
        #expect(service.currentStatus.viewers.first?.name == "viewer1")
        #expect(service.currentStatus.viewers.last?.name == "late")
        clients.forEach { $0.disconnect() }
        late.disconnect()
    }
}
