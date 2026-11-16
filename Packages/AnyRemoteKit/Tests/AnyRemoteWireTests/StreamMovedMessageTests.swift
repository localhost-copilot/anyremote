import Foundation
import Testing
@testable import AnyRemoteWire

/// The window a stream moved to (a tab taking its window's place) is an
/// optional addition to `streamMoved`, so viewers and hosts from before it
/// still understand each other.
@Suite struct StreamMovedMessageTests {
    private let frame = CGRect(x: 10, y: 20, width: 800, height: 600)

    @Test func windowRoundTrips() throws {
        let messages: [ControlMessage] = [
            .streamMoved(streamID: 4, frame: frame, title: "zsh", windowID: 164_357),
            .streamMoved(streamID: 4, frame: frame, title: "zsh"),
        ]
        for message in messages {
            #expect(try ControlCoding.decode(ControlMessage.self, from: ControlCoding.encode(message)) == message)
        }
    }

    @Test func olderHostsSendNoWindow() throws {
        let message = try ControlCoding.encode(ControlMessage.streamMoved(streamID: 4, frame: frame, title: "zsh"))
        let json = try #require(String(data: message, encoding: .utf8))
        #expect(!json.contains("windowID"))
        #expect(try ControlCoding.decode(ControlMessage.self, from: message)
            == .streamMoved(streamID: 4, frame: frame, title: "zsh", windowID: nil))
    }

    @Test func olderViewersIgnoreTheWindow() throws {
        struct OldMoved: Decodable { let streamID: UInt16; let frame: CGRect; let title: String }
        struct OldMessage: Decodable { let streamMoved: OldMoved? }
        let old = try JSONDecoder().decode(OldMessage.self, from: ControlCoding.encode(
            ControlMessage.streamMoved(streamID: 4, frame: frame, title: "zsh", windowID: 9)))
        #expect(old.streamMoved?.title == "zsh")
    }
}
