import CoreGraphics
import Foundation
import Testing
@testable import AnyRemoteWire

@Suite struct StatusItemMessageTests {
    @Test func statusItemMessagesRoundTrip() throws {
        let item = HostStatusItem(id: "2599:com.bjango.istatmenus.cpu", applicationName: "iStat Menus",
                                  bundleIdentifier: "com.bjango.istatmenus", title: "CPU 你好",
                                  image: Data([0x89, 0x50, 0x4E, 0x47]), frame: CGRect(x: 1510, y: 3, width: 19, height: 24))
        let messages: [ControlMessage] = [
            .listStatusItems(requestID: 7),
            .statusItems(requestID: 7, items: [item, HostStatusItem(id: "85018#0", applicationName: "Amphetamine",
                                                                    bundleIdentifier: nil, title: "", image: nil,
                                                                    frame: .zero)]),
            .statusItems(requestID: 8, items: []),
            .openStatusItem(id: item.id),
            .statusItemMenu(id: item.id, menus: [MenuNode(title: "Start", children: [MenuNode(title: "Now")]),
                                                 MenuNode(title: "", isSeparator: true)]),
            .performStatusItemMenu(id: item.id, path: [0, 0]),
            .performStatusItemMenu(id: item.id, path: nil),
        ]
        for message in messages {
            let data = try ControlCoding.encode(message)
            #expect(try ControlCoding.decode(ControlMessage.self, from: data) == message)
        }
    }

    @Test func popupStreamsRoundTrip() throws {
        let data = try ControlCoding.encode(StreamDescription.Role.popup)
        #expect(try ControlCoding.decode(StreamDescription.Role.self, from: data) == .popup)
    }
}
