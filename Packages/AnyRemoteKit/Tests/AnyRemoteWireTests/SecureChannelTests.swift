import CryptoKit
import Foundation
import Testing
@testable import AnyRemoteWire

@Suite struct SecureChannelTests {
    private func keys(_ code: PairingCode = PairingCode("ABCDE-FGHJK-MNPQR-STVWX")!) throws -> SessionKeys {
        try SessionKeys(preSharedKey: code.preSharedKey, clientNonce: Data(repeating: 1, count: 32),
                        serverNonce: Data(repeating: 2, count: 32))
    }

    @Test func streamSealRoundTripAndOrdering() throws {
        let keys = try keys()
        var sealer = StreamSealer(key: keys.controlViewerToHost)
        var opener = StreamOpener(key: keys.controlViewerToHost)
        let first = try sealer.seal(Data("one".utf8))
        let second = try sealer.seal(Data("two".utf8))
        // Out of order: the second frame fails against counter 0.
        var reordered = opener
        #expect(throws: WireError.authenticationFailed) { try reordered.open(second) }
        #expect(try opener.open(first) == Data("one".utf8))
        #expect(try opener.open(second) == Data("two".utf8))
        // Replaying an accepted frame fails.
        #expect(throws: WireError.authenticationFailed) { try opener.open(first) }
    }

    @Test func wrongPairingCodeCannotOpen() throws {
        let right = try keys()
        let wrong = try keys(PairingCode("ZZZZZ-FGHJK-MNPQR-STVWX")!)
        var sealer = StreamSealer(key: right.controlViewerToHost)
        var opener = StreamOpener(key: wrong.controlViewerToHost)
        let sealed = try sealer.seal(Data("hello".utf8))
        #expect(throws: WireError.authenticationFailed) { try opener.open(sealed) }
    }

    @Test func directionsUseDistinctKeys() throws {
        let keys = try keys()
        var sealer = StreamSealer(key: keys.controlViewerToHost)
        var opener = StreamOpener(key: keys.controlHostToViewer)
        #expect(throws: WireError.authenticationFailed) { try opener.open(try sealer.seal(Data([1]))) }
    }

    @Test func datagramRoundTripTamperAndReplay() throws {
        let keys = try keys()
        let sealer = DatagramSealer(key: keys.datagramHostToViewer, sessionID: 7)
        var opener = DatagramOpener(key: keys.datagramHostToViewer, sessionID: 7)
        let a = try sealer.seal(Data("a".utf8))
        let b = try sealer.seal(Data("b".utf8))
        #expect(DatagramEnvelope.sessionID(of: a) == 7)
        // Reordering is fine for datagrams.
        #expect(try opener.open(b) == Data("b".utf8))
        #expect(try opener.open(a) == Data("a".utf8))
        #expect(throws: WireError.replayed) { try opener.open(a) }
        var tampered = try sealer.seal(Data("c".utf8))
        tampered[tampered.startIndex + 5] ^= 0xFF // counter byte (authenticated header)
        #expect(throws: (any Error).self) { try opener.open(tampered) }
        var otherSession = DatagramOpener(key: keys.datagramHostToViewer, sessionID: 8)
        #expect(throws: (any Error).self) { try otherSession.open(try sealer.seal(Data([1]))) }
    }

    @Test func replayWindowSlides() {
        var window = ReplayWindow()
        window.record(0)
        window.record(5)
        #expect(!window.mayAccept(0))
        #expect(window.mayAccept(3))
        window.record(3)
        #expect(!window.mayAccept(3))
        window.record(5000)
        #expect(!window.mayAccept(5))       // fell out of the window
        #expect(window.mayAccept(4999))
        #expect(!window.mayAccept(5000))
        #expect(window.mayAccept(4500))
    }

    @Test func controlFrameParserHandlesSplitsAndBatches() throws {
        let a = ControlFrame.encode(kind: .handshake, body: Data("first".utf8))
        let b = ControlFrame.encode(kind: .sealed, body: Data(repeating: 9, count: 3000))
        var parser = ControlFrameParser()
        let stream = a + b
        var frames: [(ControlFrame.Kind, Data)] = []
        var offset = 0
        for size in [1, 3, 2, 10, 500, 4000] where offset < stream.count {
            let end = min(stream.count, offset + size)
            frames += try parser.append(stream.subdata(in: offset..<end))
            offset = end
        }
        #expect(frames.count == 2)
        #expect(frames[0].0 == .handshake && frames[0].1 == Data("first".utf8))
        #expect(frames[1].0 == .sealed && frames[1].1.count == 3000)
        var hostile = ControlFrameParser()
        #expect(throws: WireError.oversized) { try hostile.append(Data([0xFF, 0xFF, 0xFF, 0xFF, 1])) }
    }

    @Test func pairingCodeNormalizes() throws {
        let code = PairingCode.generate()
        #expect(code.canonical.count == 20)
        #expect(PairingCode(code.description) == code)
        #expect(PairingCode(code.description.lowercased()) == code)
        #expect(PairingCode("o1234-56789-ABCDE-FGHJI")?.canonical == "01234567 89ABCDEFGHJ1".replacingOccurrences(of: " ", with: ""))
        #expect(PairingCode("short") == nil)
        #expect(PairingCode("UUUUU-UUUUU-UUUUU-UUUUU") == nil) // U is not in the alphabet
        #expect(code.description.split(separator: "-").count == 4)
    }

    @Test func clockSyncPicksLowestRoundTrip() {
        var sync = ClockSync()
        // Host clock is 1_000_000 ahead. A slow sample has asymmetric delay.
        sync.add(viewerSent: 100, hostTime: 1_000_100 + 400, viewerReceived: 1_000)
        sync.add(viewerSent: 2_000, hostTime: 1_002_010, viewerReceived: 2_020)
        #expect(sync.best?.roundTripNanos == 20)
        #expect(sync.best?.offsetNanos == 1_000_000)
        #expect(sync.viewerTime(fromHost: 1_005_000) == 5_000)
    }

    @Test func controlMessagesRoundTrip() throws {
        let messages: [ControlMessage] = [
            .authenticate(viewerName: "mini", takeOver: true),
            .input(streamID: 3, .mouseDown(point: CGPoint(x: 1.5, y: 2), button: .left, buttonNumber: 0,
                                           clickCount: 2, modifiers: 0x100000)),
            .input(streamID: 3, .scroll(point: .zero, deltaX: -1.25, deltaY: 4, precise: true, phase: 4,
                                        momentumPhase: 0, modifiers: 0)),
            .streamStarted(StreamDescription(streamID: 2, windowID: 99, role: .child, parentStreamID: 1,
                                             frame: CGRect(x: 1, y: 2, width: 3, height: 4), layer: 101,
                                             title: "", applicationName: "Finder")),
            .windowList(requestID: 1, windows: [], displays: [], missingPermissions: ["accessibility"]),
            .menuBar(streamID: 1, applicationName: "TextEdit",
                     menus: [MenuNode(title: "File", children: [MenuNode(title: "New", keyEquivalent: "N")])]),
        ]
        for message in messages {
            let decoded = try ControlCoding.decode(ControlMessage.self, from: try ControlCoding.encode(message))
            #expect(decoded == message)
        }
    }
}
