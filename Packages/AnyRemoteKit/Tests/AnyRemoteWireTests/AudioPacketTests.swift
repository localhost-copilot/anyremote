import Foundation
import Testing
@testable import AnyRemoteWire

@Suite struct AudioPacketTests {
    @Test func roundTripWithPreviousUnit() throws {
        let packet = AudioPacket(sequence: 0xFFFF_FFFF, captureNanos: 123_456_789_000,
                                 accessUnit: Data([1, 2, 3]), previousAccessUnit: Data([9, 8]))
        let datagram = try packet.serialized()
        #expect(try AudioPacket.parse(datagram) == packet)
    }

    @Test func goldenHeader() throws {
        let datagram = try AudioPacket(sequence: 7, captureNanos: 0x0102_0304_0506_0708,
                                       accessUnit: Data([0xAA])).serialized()
        #expect(Array(datagram) == [1, DatagramKind.audio, 0, 0, 0, 0, 0, 7,
                                    1, 2, 3, 4, 5, 6, 7, 8, 0, 1, 0xAA, 0, 0])
        #expect(try AudioPacket.parse(datagram).previousAccessUnit == nil)
    }

    @Test func microphonePacketsKeepTheirKind() throws {
        let packet = AudioPacket(kind: DatagramKind.microphone, sequence: 3, captureNanos: 42,
                                 accessUnit: Data([5, 6]), previousAccessUnit: Data([4]))
        let datagram = try packet.serialized()
        #expect(datagram[1] == DatagramKind.microphone)
        #expect(try AudioPacket.parse(datagram) == packet)
    }

    @Test func microphoneMessagesRoundTrip() throws {
        let format = AudioStreamFormat(magicCookie: Data([1, 2, 3]))
        for message in [ControlMessage.microphone(enabled: true), .microphoneWanted(true), .microphoneWanted(false),
                        .microphoneStream(format), .microphoneStream(nil)] {
            let data = try ControlCoding.encode(message)
            #expect(try ControlCoding.decode(ControlMessage.self, from: data) == message)
        }
    }

    @Test func rejectsTruncatedAndForeignDatagrams() throws {
        let datagram = try AudioPacket(sequence: 1, captureNanos: 1, accessUnit: Data([1, 2])).serialized()
        #expect(throws: WireError.self) { try AudioPacket.parse(datagram.prefix(datagram.count - 3)) }
        var video = datagram
        video[1] = DatagramKind.video
        #expect(throws: WireError.unknownKind(DatagramKind.video)) { try AudioPacket.parse(video) }
        #expect(throws: WireError.oversized) { try AudioPacket(sequence: 1, captureNanos: 1, accessUnit: Data()).serialized() }
    }
}
