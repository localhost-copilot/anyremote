import Foundation

/// One viewer's video bit rate for one stream, adapted to its once-a-second
/// receiver reports. The stream runs at the lowest of its viewers' rates.
///
/// - A lost frame cuts the rate to 3/4.
/// - So does a queue in the network (`congestedQueuing` or more): the link
///   carries less than is sent, without losing anything yet. After such a cut
///   the queue takes a while to drain, so for `drainTime` further delay
///   reports don't cut again; loss still does. Every strip of a desktop
///   reports, so the hold is by time rather than by report.
/// - Four clean reports in a row raise it by 10%. A report that shows some
///   queuing (`risingQueuing`) isn't clean: the link is near its limit.
struct ViewerRateControl {
    var bitRate: Int
    private var cleanReports = 0
    private var lastDelayCutNanos: UInt64?

    static let congestedQueuing: Double = 30
    static let risingQueuing: Double = 10
    static let drainTime: UInt64 = 2_000_000_000
    static let cleanReportsToRaise = 4

    init(bitRate: Int) {
        self.bitRate = bitRate
    }

    /// `received` is 0 for a report that may only cut (a desktop strip other
    /// than the first).
    mutating func report(received: UInt32, dropped: UInt32, queuingMilliseconds: Double?,
                         floor: Int, ceiling: Int, now: UInt64) {
        let queuing = queuingMilliseconds ?? 0
        if dropped > 0 {
            cut(floor: floor)
        } else if queuing >= Self.congestedQueuing {
            cleanReports = 0
            if lastDelayCutNanos.map({ now - $0 >= Self.drainTime }) ?? true {
                cut(floor: floor)
                lastDelayCutNanos = now
            }
        } else if queuing >= Self.risingQueuing {
            cleanReports = 0
        } else if received > 0 {
            cleanReports += 1
            if cleanReports >= Self.cleanReportsToRaise {
                bitRate = min(ceiling, bitRate + bitRate / 10)
                cleanReports = 0
            }
        }
        bitRate = min(bitRate, ceiling)
    }

    private mutating func cut(floor: Int) {
        bitRate = max(floor, bitRate * 3 / 4)
        cleanReports = 0
    }
}
