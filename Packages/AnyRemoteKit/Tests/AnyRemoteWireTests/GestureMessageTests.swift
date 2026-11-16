import Foundation
import Testing
@testable import AnyRemoteWire

@Suite struct GestureMessageTests {
    @Test func gesturesRoundTrip() throws {
        let point = CGPoint(x: 120.5, y: 48)
        for event: InputEvent in [.gesture(point: point, kind: .magnify, phase: 4, value: 0.05, modifiers: 0),
                                  .gesture(point: point, kind: .rotate, phase: 1, value: -12.5, modifiers: 1 << 20),
                                  .gesture(point: point, kind: .smartMagnify, phase: 0, value: 0, modifiers: 0)] {
            let message = ControlMessage.input(streamID: 3, event)
            #expect(try ControlCoding.decode(ControlMessage.self, from: ControlCoding.encode(message)) == message)
        }
    }
}
