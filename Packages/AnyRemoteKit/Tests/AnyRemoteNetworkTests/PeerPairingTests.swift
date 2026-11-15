@testable import AnyRemoteClient
import AnyRemoteWire
import Foundation
import Testing

struct PeerPairingTests {
    let code = PairingCode.generate().canonical

    func offer(_ code: String?, usesAddress: Bool = false) -> PeerPairing {
        PeerPairing(hostID: "A", name: "Mac A", pairingCode: code, port: 47800, usesAddress: usesAddress)
    }

    @Test func offerAddsTheMacOverBonjour() {
        let (hosts, outcome) = PairedHostStore.applying(offer(code), address: "10.0.0.2:47800", ownID: "B", to: [])
        #expect(outcome == .added)
        #expect(hosts.count == 1)
        #expect(hosts[0].fromPeer && hosts[0].bonjourName == "Mac A" && hosts[0].address == nil)
        #expect(hosts[0].pairingCode == code)
    }

    @Test func offerByAddressKeepsTheAddress() {
        let (hosts, _) = PairedHostStore.applying(offer(code, usesAddress: true), address: "10.0.0.2:47800",
                                                  ownID: "B", to: [])
        #expect(hosts[0].address == "10.0.0.2:47800" && hosts[0].bonjourName == nil)
    }

    @Test func newCodeReplacesTheOldOneButKeepsTheName() {
        let old = PairedHost(id: "A", name: "Renamed", address: nil, bonjourName: "Mac A",
                             pairingCode: PairingCode.generate().canonical)
        let (hosts, outcome) = PairedHostStore.applying(offer(code), address: nil, ownID: "B", to: [old])
        #expect(outcome == .codeChanged)
        #expect(hosts[0].pairingCode == code && hosts[0].name == "Renamed" && !hosts[0].fromPeer)
    }

    @Test func withdrawalRemovesOnlyOfferedMacs() {
        let offered = PairedHost(id: "A", name: "Mac A", address: nil, bonjourName: "Mac A", pairingCode: code,
                                 fromPeer: true)
        #expect(PairedHostStore.applying(offer(nil), address: nil, ownID: "B", to: [offered]).1 == .removed)
        var manual = offered
        manual.fromPeer = false
        #expect(PairedHostStore.applying(offer(nil), address: nil, ownID: "B", to: [manual]).1 == .unchanged)
    }

    @Test func ownOfferAndBadCodesAreIgnored() {
        #expect(PairedHostStore.applying(offer(code), address: nil, ownID: "A", to: []).1 == .unchanged)
        #expect(PairedHostStore.applying(offer("nope"), address: nil, ownID: "B", to: []).1 == .unchanged)
    }

    @Test func oldStoresDecodeWithDefaults() throws {
        let json = #"[{"id":"A","name":"Mac A","pairingCode":"\#(code)"}]"#
        let hosts = try JSONDecoder().decode([PairedHost].self, from: Data(json.utf8))
        #expect(!hosts[0].fromPeer && hosts[0].sharesBack)
    }
}
