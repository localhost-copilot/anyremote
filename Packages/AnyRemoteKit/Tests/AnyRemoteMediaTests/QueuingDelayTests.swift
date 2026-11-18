import Testing
@testable import AnyRemoteMedia

@Suite struct QueuingDelayTests {
    @Test func measuresAgainstTheFastestFrameOfTheLastMinute() {
        var delay = QueuingDelay()
        #expect(delay.take() == nil)
        // A keyframe takes 40 ms on its own; the small frames 3 ms.
        for transit in [40.0, 3, 4, 3.5] { delay.record(transitMilliseconds: transit) }
        #expect(delay.take() == 0)
        // A queue stands: even the fastest frame waits 60 ms more.
        for transit in [110.0, 63, 70] { delay.record(transitMilliseconds: transit) }
        #expect(delay.take() == 60)
    }

    @Test func forgetsFloorsOlderThanAMinute() {
        var delay = QueuingDelay()
        delay.record(transitMilliseconds: 2)
        _ = delay.take()
        for _ in 0..<QueuingDelay.historyLength {
            delay.record(transitMilliseconds: 10)
            _ = delay.take()
        }
        delay.record(transitMilliseconds: 10)
        #expect(delay.take() == 0)
    }
}
