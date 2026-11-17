@testable import AnyRemoteClient
import AnyRemoteWire
import Foundation
import Testing

struct PeerPairingTests {
    let key = PairingCredential.generate()

    func offer(_ credential: PairingCredential?, usesAddress: Bool = false) -> PeerPairing {
        PeerPairing(hostID: "A", name: "Mac A", credential: credential, port: 47800, usesAddress: usesAddress)
    }

    @Test func offerAddsTheMacOverBonjour() {
        let (hosts, outcome) = PairedHostStore.applying(offer(key), address: "10.0.0.2:47800", ownID: "B", to: [])
        #expect(outcome == .added)
        #expect(hosts.count == 1)
        #expect(hosts[0].fromPeer && hosts[0].bonjourName == "Mac A" && hosts[0].address == nil)
        #expect(hosts[0].credential == key)
    }

    @Test func offerByAddressKeepsTheAddress() {
        let (hosts, _) = PairedHostStore.applying(offer(key, usesAddress: true), address: "10.0.0.2:47800",
                                                  ownID: "B", to: [])
        #expect(hosts[0].address == "10.0.0.2:47800" && hosts[0].bonjourName == nil)
    }

    @Test func aKeyOfItsOwnReplacesTheLegacyCodeButKeepsTheName() {
        let old = PairedHost(id: "A", name: "Renamed", address: nil, bonjourName: "Mac A",
                             credential: .legacy(.generate()))
        let (hosts, outcome) = PairedHostStore.applying(offer(key), address: nil, ownID: "B", to: [old])
        #expect(outcome == .keyChanged)
        #expect(hosts[0].credential == key && hosts[0].name == "Renamed" && !hosts[0].fromPeer)
    }

    @Test func aKeyPairedHereIsNotReplacedByAnOffer() {
        let paired = PairedHost(id: "A", name: "Mac A", address: nil, bonjourName: "Mac A", credential: .generate())
        #expect(PairedHostStore.applying(offer(key), address: nil, ownID: "B", to: [paired]).1 == .unchanged)
        var offered = paired
        offered.fromPeer = true
        #expect(PairedHostStore.applying(offer(key), address: nil, ownID: "B", to: [offered]).1 == .keyChanged)
    }

    @Test func offeredMacThatMovedKeepsItsNewAddress() {
        let moved = PairedHost(id: "A", name: "Mac A", address: "192.168.50.20:47800", bonjourName: nil,
                               credential: key, fromPeer: true)
        let (hosts, outcome) = PairedHostStore.applying(offer(key, usesAddress: true), address: "192.168.6.238:47800",
                                                        ownID: "B", to: [moved])
        #expect(outcome == .addressChanged && hosts[0].address == "192.168.6.238:47800")
        // One paired here by hand keeps the address it was given.
        var manual = moved
        manual.fromPeer = false
        #expect(PairedHostStore.applying(offer(key, usesAddress: true), address: "192.168.6.238:47800",
                                         ownID: "B", to: [manual]).1 == .unchanged)
    }

    @Test func withdrawalRemovesOnlyOfferedMacs() {
        let offered = PairedHost(id: "A", name: "Mac A", address: nil, bonjourName: "Mac A", credential: key,
                                 fromPeer: true)
        #expect(PairedHostStore.applying(offer(nil), address: nil, ownID: "B", to: [offered]).1 == .removed)
        var manual = offered
        manual.fromPeer = false
        #expect(PairedHostStore.applying(offer(nil), address: nil, ownID: "B", to: [manual]).1 == .unchanged)
    }

    @Test func ownOfferAndLegacyOffersAreIgnored() {
        #expect(PairedHostStore.applying(offer(key), address: nil, ownID: "A", to: []).1 == .unchanged)
        #expect(PairedHostStore.applying(offer(.legacy(.generate())), address: nil, ownID: "B", to: []).1 == .unchanged)
    }

    /// Stores from before 0.31 hold each Mac's shared code.
    @Test func oldStoresDecodeWithTheLegacyCode() throws {
        let code = PairingCode.generate()
        let json = #"[{"id":"A","name":"Mac A","pairingCode":"\#(code.canonical)"}]"#
        let hosts = try JSONDecoder().decode([PairedHost].self, from: Data(json.utf8))
        #expect(!hosts[0].fromPeer && hosts[0].sharesBack && hosts[0].maximumBitRate == nil)
        #expect(hosts[0].frameRate == nil)
        #expect(hosts[0].credential == .legacy(code))
        // Saved again, it keeps working.
        let again = try JSONDecoder().decode([PairedHost].self, from: JSONEncoder().encode(hosts))
        #expect(again[0].credential == .legacy(code))
    }

    @Test func aMacAddedByAddressHasNoKeyUntilPaired() throws {
        let host = PairedHost(id: "address:x", name: "x", address: "x:47800", bonjourName: nil, credential: nil)
        let decoded = try JSONDecoder().decode(PairedHost.self, from: JSONEncoder().encode(host))
        #expect(decoded.credential == nil)
    }

    @Test func frameRateIsKept() throws {
        let host = PairedHost(id: "A", name: "Mac A", address: nil, bonjourName: "Mac A", credential: key,
                              fromPeer: true, frameRate: 120)
        let decoded = try JSONDecoder().decode(PairedHost.self, from: JSONEncoder().encode(host))
        #expect(decoded.frameRate == 120)
        let (hosts, _) = PairedHostStore.applying(offer(.generate()), address: nil, ownID: "B", to: [host])
        #expect(hosts[0].frameRate == 120)
    }

    @Test func videoCapIsKept() throws {
        let host = PairedHost(id: "A", name: "Mac A", address: nil, bonjourName: "Mac A", credential: key,
                              fromPeer: true, maximumBitRate: 30_000_000)
        let decoded = try JSONDecoder().decode(PairedHost.self, from: JSONEncoder().encode(host))
        #expect(decoded.maximumBitRate == 30_000_000)
        // A new key from that Mac must not reset the cap.
        let (hosts, _) = PairedHostStore.applying(offer(.generate()), address: nil, ownID: "B", to: [host])
        #expect(hosts[0].maximumBitRate == 30_000_000)
    }
}
