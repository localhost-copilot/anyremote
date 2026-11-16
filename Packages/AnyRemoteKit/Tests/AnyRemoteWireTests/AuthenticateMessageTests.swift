import Foundation
import Testing
@testable import AnyRemoteWire

/// The viewer's screens are optional additions to `authenticate` and
/// `focus`, so viewers and hosts from before them still understand each other.
@Suite struct AuthenticateMessageTests {
    private let screen = ViewerScreen(id: 2, size: CGSize(width: 1920, height: 1080))

    @Test func screensRoundTrip() throws {
        let messages: [ControlMessage] = [
            .authenticate(viewerName: "MacBook Pro", takeOver: false, screen: screen),
            .focus(streamID: 7, screen: screen),
            .focus(streamID: 7),
        ]
        for message in messages {
            #expect(try ControlCoding.decode(ControlMessage.self, from: ControlCoding.encode(message)) == message)
        }
    }

    @Test func videoCapRoundTrips() throws {
        for message: ControlMessage in [.maximumBitRate(30_000_000), .maximumBitRate(nil)] {
            #expect(try ControlCoding.decode(ControlMessage.self, from: ControlCoding.encode(message)) == message)
        }
    }

    @Test func olderViewersDecodeWithoutScreens() throws {
        // What viewers before the screens send.
        let authenticate = Data(#"{"authenticate":{"viewerName":"mini","takeOver":true}}"#.utf8)
        #expect(try ControlCoding.decode(ControlMessage.self, from: authenticate)
            == .authenticate(viewerName: "mini", takeOver: true, screen: nil))
        let focus = Data(#"{"focus":{"streamID":3}}"#.utf8)
        #expect(try ControlCoding.decode(ControlMessage.self, from: focus) == .focus(streamID: 3, screen: nil))
    }

    @Test func olderHostsIgnoreScreens() throws {
        // A host before the screens decodes these cases without them; the
        // extra key must not make the messages unreadable.
        struct OldAuthenticate: Decodable { let viewerName: String; let takeOver: Bool }
        struct OldFocus: Decodable { let streamID: UInt16 }
        struct OldMessage: Decodable { let authenticate: OldAuthenticate?; let focus: OldFocus? }
        let authenticate = try JSONDecoder().decode(OldMessage.self, from: ControlCoding.encode(
            ControlMessage.authenticate(viewerName: "mini", takeOver: false, screen: screen)))
        #expect(authenticate.authenticate?.viewerName == "mini")
        let focus = try JSONDecoder().decode(OldMessage.self, from: ControlCoding.encode(
            ControlMessage.focus(streamID: 9, screen: screen)))
        #expect(focus.focus?.streamID == 9)
    }
}
