@testable import AnyRemoteHost
import AnyRemoteWire
import CoreGraphics
import Foundation
import Testing

struct TextInputTests {
    @Test func textSplitsBetweenCharacters() {
        let chunks = InputInjector.chunks(of: "你好，世界")
        #expect(chunks.count == 1)
        #expect(String(utf16CodeUnits: chunks[0], count: chunks[0].count) == "你好，世界")

        // 👍🏽 is four UTF-16 units and one character: it never straddles two events.
        let text = String(repeating: "あ", count: 18) + "👍🏽" + "い"
        let split = InputInjector.chunks(of: text)
        #expect(split.allSatisfy { $0.count <= 20 })
        #expect(split.map { String(utf16CodeUnits: $0, count: $0.count) } == [String(repeating: "あ", count: 18),
                                                                              "👍🏽い"])
        #expect(InputInjector.chunks(of: "").isEmpty)
    }

    @Test func textMessagesRoundTrip() throws {
        for message: ControlMessage in [.input(streamID: 2, .text("你好，世界")),
                                        .caret(streamID: 2, rect: CGRect(x: 5, y: 32, width: 1, height: 23)),
                                        .caret(streamID: 2, rect: CGRect(x: 5, y: 32, width: 1, height: 23),
                                               font: CaretFont(name: "Menlo-Regular", size: 13)),
                                        .caret(streamID: 2, rect: nil)] {
            let data = try ControlCoding.encode(message)
            #expect(try ControlCoding.decode(ControlMessage.self, from: data) == message)
        }
    }

    @Test func caretWithoutFontDecodes() throws {
        // A 0.12.0 host sends no font; the viewer still takes the caret.
        let json = #"{"caret":{"streamID":2,"rect":[[5,32],[1,23]]}}"#
        #expect(try ControlCoding.decode(ControlMessage.self, from: Data(json.utf8))
                == .caret(streamID: 2, rect: CGRect(x: 5, y: 32, width: 1, height: 23), font: nil))
    }
}
