import AnyRemoteWire
import Foundation
import Testing
@testable import AnyRemoteHost

@Suite struct ViewerRateControlTests {
    private let floor = 6_000_000
    private let ceiling = 80_000_000
    private let second: UInt64 = 1_000_000_000

    @Test func lossCutsAndCleanReportsRaise() {
        var rate = ViewerRateControl(bitRate: 40_000_000)
        rate.report(received: 60, dropped: 2, queuingMilliseconds: nil, floor: floor, ceiling: ceiling, now: 0)
        #expect(rate.bitRate == 30_000_000)
        for index in 1...4 {
            rate.report(received: 60, dropped: 0, queuingMilliseconds: 0, floor: floor, ceiling: ceiling,
                        now: UInt64(index) * second)
        }
        #expect(rate.bitRate == 33_000_000)
    }

    /// A queue in the network cuts like loss, once per drain time, however
    /// many strips report it.
    @Test func queuingCutsOncePerDrainTime() {
        var rate = ViewerRateControl(bitRate: 40_000_000)
        rate.report(received: 60, dropped: 0, queuingMilliseconds: 120, floor: floor, ceiling: ceiling, now: 0)
        #expect(rate.bitRate == 30_000_000)
        // Three more strips' reports of the same second, then the next second.
        for _ in 0..<3 {
            rate.report(received: 0, dropped: 0, queuingMilliseconds: 120, floor: floor, ceiling: ceiling, now: 1000)
        }
        rate.report(received: 60, dropped: 0, queuingMilliseconds: 90, floor: floor, ceiling: ceiling, now: second)
        #expect(rate.bitRate == 30_000_000)
        rate.report(received: 60, dropped: 0, queuingMilliseconds: 60, floor: floor, ceiling: ceiling, now: 2 * second)
        #expect(rate.bitRate == 22_500_000)
        // Loss still cuts during the hold.
        rate.report(received: 60, dropped: 1, queuingMilliseconds: 60, floor: floor, ceiling: ceiling,
                    now: 2 * second + 1)
        #expect(rate.bitRate == 16_875_000)
    }

    @Test func someQueuingHoldsTheRate() {
        var rate = ViewerRateControl(bitRate: 40_000_000)
        for index in 0..<8 {
            rate.report(received: 60, dropped: 0, queuingMilliseconds: 15, floor: floor, ceiling: ceiling,
                        now: UInt64(index) * second)
        }
        #expect(rate.bitRate == 40_000_000)
    }

    @Test func neverBelowTheFloor() {
        var rate = ViewerRateControl(bitRate: 7_000_000)
        rate.report(received: 60, dropped: 0, queuingMilliseconds: 200, floor: floor, ceiling: ceiling, now: 0)
        #expect(rate.bitRate == floor)
    }

    /// Viewers before the field still decode, and a host before it ignores it.
    @Test func reportsWithoutQueuingStillDecode() throws {
        let old = #"{"receiverReport":{"streamID":3,"framesReceived":60,"framesDropped":1}}"#
        #expect(try ControlCoding.decode(ControlMessage.self, from: Data(old.utf8))
            == .receiverReport(streamID: 3, framesReceived: 60, framesDropped: 1, queuingMilliseconds: nil))
        let new = ControlMessage.receiverReport(streamID: 3, framesReceived: 60, framesDropped: 0, queuingMilliseconds: 42.5)
        #expect(try ControlCoding.decode(ControlMessage.self, from: ControlCoding.encode(new)) == new)
    }
}
