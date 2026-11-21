import AnyRemoteNetwork
import AnyRemoteWire
import Darwin
import Foundation
import Testing

struct TailnetTests {
    @Test func recognizesTailscaleAddresses() {
        #expect(TailnetAddress.isTailnet("100.86.208.99"))
        #expect(TailnetAddress.isTailnet("100.64.0.1"))
        #expect(TailnetAddress.isTailnet("100.127.255.254"))
        #expect(TailnetAddress.isTailnet("fd7a:115c:a1e0::d33:b04e"))
        #expect(TailnetAddress.isTailnet("[fd7a:115c:a1e0::1]"))
        #expect(!TailnetAddress.isTailnet("100.128.0.1"))
        #expect(!TailnetAddress.isTailnet("192.168.6.238"))
        #expect(!TailnetAddress.isTailnet("fd7a:115c:a1e1::1"))
        #expect(!TailnetAddress.isTailnet("mac-mini.local"))
    }

    /// A host's virtual machine networks aren't ways to it; a Thunderbolt Bridge is.
    @Test func leavesOutVirtualMachineNetworks() {
        #expect(LocalAddresses.isVirtualMachineBridge("bridge100"))
        #expect(LocalAddresses.isVirtualMachineBridge("bridge107"))
        #expect(!LocalAddresses.isVirtualMachineBridge("bridge0"))
        #expect(!LocalAddresses.isVirtualMachineBridge("en0"))
    }

    /// Ethernet keeps the 1400 bytes AnyRemote always sent; the tailnet's
    /// 1280-byte tunnel gets datagrams it carries whole.
    @Test func sizesDatagramsForThePath() {
        #expect(PathMTU.datagramPayload(mtu: 1500, ipv6: false) == 1400)
        #expect(PathMTU.datagramPayload(mtu: 16384, ipv6: true) == 1400)
        #expect(PathMTU.datagramPayload(mtu: PathMTU.tailnet, ipv6: false) == 1252)
        #expect(PathMTU.datagramPayload(mtu: PathMTU.tailnet, ipv6: true) == 1232)
        #expect(PathMTU.datagramPayload(mtu: nil, ipv6: false) == 1400)
        #expect(PathMTU.interface("lo0") ?? 0 >= 1280)
    }

    /// The node's status, as Tailnet/tailnet.go writes it.
    @Test func decodesTheNodeStatus() throws {
        let json = """
        {"state":"Running","tailnet":"example.com","user":"someone@example.com",
         "self":{"id":"n1","hostName":"mac-mini","dnsName":"mac-mini-anyremote.tail1234.ts.net","os":"macOS",
                 "online":true,"addresses":["100.75.176.77","fd7a:115c:a1e0::d33:b04e"],
                 "keyExpiry":"2027-05-20T10:00:00.123456789Z"},
         "peers":[{"id":"n2","hostName":"MacBook Pro","dnsName":"kai-macbook-pro.tail1234.ts.net","os":"macOS",
                   "online":true,"addresses":["fd7a:115c:a1e0::1","100.86.208.99"],"curAddr":"192.168.6.20:41641"},
                  {"id":"n3","hostName":"nas","dnsName":"nas.tail1234.ts.net","os":"linux","online":false,
                   "addresses":["100.70.0.3"],"relay":"tok"}],
         "droppedInbound":0,"droppedOutbound":2}
        """
        let status = try #require(TailnetStatus.decode(Data(json.utf8)))
        #expect(status.isRunning)
        #expect(status.device?.name == "mac-mini-anyremote")
        let expiry = try #require(status.device?.keyExpiry)
        #expect(abs(expiry.timeIntervalSince1970 - 1_810_807_200) < 1)
        #expect(status.peers[0].preferredAddress == "100.86.208.99")
        #expect(status.peers[0].path == .direct)
        #expect(status.peers[1].path == .derp)
        #expect(status.droppedOutbound == 2)
    }

    /// A host from before 0.32 sends no tailnet addresses.
    @Test func welcomeWithoutTailnetAddressesDecodes() throws {
        let json = #"{"hostID":"h","hostName":"Mac","datagramPort":5000,"displays":[],"missingPermissions":[]}"#
        let welcome = try JSONDecoder().decode(HostWelcome.self, from: Data(json.utf8))
        #expect(welcome.tailnetAddresses == nil)
        #expect(welcome.datagramPort == 5000)
    }

    /// A tailnet socket's datagrams carry the peer's address in front.
    @Test func tailnetDatagramsCarryThePeerAddress() async throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0)
        defer { close(fds[1]) }
        let socket = DatagramSocket(tailnetDescriptor: fds[0], queue: DispatchQueue(label: "test.udp"))
        let received = Received()
        socket.onReceive = { batch in received.add(batch) }
        socket.resume()
        defer { socket.cancel() }
        let incoming: [UInt8] = [4, 0xba, 0xb8, 100, 86, 208, 99] + Array("video".utf8)
        #expect(write(fds[1], incoming, incoming.count) == incoming.count)
        for _ in 0..<100 where received.batches.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let (payload, address) = try #require(received.batches.first)
        #expect(String(decoding: payload, as: UTF8.self) == "video")
        #expect(address.description == "100.86.208.99:47800")
        // Replies go out framed with that address.
        #expect(socket.send(Data("keepalive".utf8), to: address))
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = read(fds[1], &buffer, buffer.count)
        #expect(Array(buffer[0..<count]) == [4, 0xba, 0xb8, 100, 86, 208, 99] + Array("keepalive".utf8))
        // IPv6 peers too.
        let v6 = try #require(SocketAddress.resolve(host: "fd7a:115c:a1e0::2", port: 1))
        #expect(socket.send(Data([9]), to: v6))
        let v6Count = read(fds[1], &buffer, buffer.count)
        #expect(v6Count == 20 && buffer[0] == 6 && buffer[1] == 0 && buffer[2] == 1 && buffer[19] == 9)
    }
}

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(Data, SocketAddress)] = []
    var batches: [(Data, SocketAddress)] { lock.withLock { stored } }
    func add(_ batch: [(Data, SocketAddress)]) { lock.withLock { stored += batch } }
}
