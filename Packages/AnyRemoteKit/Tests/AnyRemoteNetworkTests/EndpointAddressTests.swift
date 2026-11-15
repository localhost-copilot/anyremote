import AnyRemoteNetwork
import Network
import Testing

struct EndpointAddressTests {
    @Test func scopedIPv4ResolvesToTheHostRatherThanADNSName() throws {
        // On-link connections can supply interface-scoped IPv4 addresses.
        let endpoint = NWEndpoint.hostPort(host: .init("192.168.50.239%lo0"), port: 47800)
        let host = try #require(endpoint.numericHost)
        #expect(host == "192.168.50.239")
        let destination = try #require(SocketAddress.resolve(host: host, port: 64716))
        #expect(destination.description == "192.168.50.239:64716")
    }

    @Test func linkLocalIPv6RetainsItsInterfaceScope() throws {
        let endpoint = NWEndpoint.hostPort(host: .init("fe80::1%lo0"), port: 47800)
        let host = try #require(endpoint.numericHost)
        #expect(host == "fe80::1%lo0")
        #expect(SocketAddress.resolve(host: host, port: 64716) != nil)
    }
}
