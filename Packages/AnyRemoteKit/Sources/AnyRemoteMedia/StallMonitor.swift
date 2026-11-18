import Foundation
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Stall")

/// Watches a stage of the viewer's video pipeline from outside it and logs
/// when the stage stops making progress, and again when it moves on.
///
/// A frozen picture used to leave nothing in the log: the stages that can
/// stop (the receive queue, the decoder, presentation) only log failures
/// they see themselves, and a stage that is stuck sees nothing. The checks
/// run on a queue of their own, so they report even while the stage, the
/// client's queue or the main thread is stuck.
public final class StallMonitor: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "anyremote.stall-monitor", qos: .utility)
    private let timer: DispatchSourceTimer
    // Monitor queue.
    private var stalled: (description: String, since: UInt64)?

    /// - Parameters:
    ///   - name: Names the stage in the log.
    ///   - check: Returns what is stuck, or nil while the stage makes
    ///     progress. Runs every half second on the monitor's queue.
    public init(name: String, check: @escaping @Sendable () -> String?) {
        timer = DispatchSource.makeTimerSource(queue: Self.queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = HostClock.nowNanos()
            switch (check(), stalled) {
            case let (description?, nil):
                stalled = (description, now)
                log.error("\(name, privacy: .public): \(description, privacy: .public)")
            case let (nil, previous?):
                stalled = nil
                let seconds = Double(now - previous.since) / 1e9
                log.notice("\(name, privacy: .public) moves again, \(seconds, format: .fixed(precision: 1)) s after it was reported stuck")
            default:
                break
            }
        }
        timer.resume()
    }

    public func cancel() { timer.cancel() }

    deinit { timer.cancel() }

    /// Seconds since `nanos`, for descriptions.
    public static func seconds(since nanos: UInt64, now: UInt64 = HostClock.nowNanos()) -> String {
        String(format: "%.1f s", Double(now &- nanos) / 1e9)
    }
}
