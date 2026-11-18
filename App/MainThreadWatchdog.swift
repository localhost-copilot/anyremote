import AnyRemoteMedia
import Foundation
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Hang")

/// Logs when the main thread stops answering for over a second, and how long
/// it was gone. A hung main thread freezes remote windows and drops clicks
/// without leaving a trace otherwise; the log tells it apart from a stalled
/// video stream (which `StallMonitor` reports).
enum MainThreadWatchdog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastAnswer: UInt64 = 0 // under `lock`

    static func start() {
        lastAnswer = HostClock.nowNanos()
        let thread = Thread { run() }
        thread.name = "anyremote.main-watchdog"
        thread.qualityOfService = .utility
        thread.start()
    }

    private static func run() {
        var hungSince: UInt64?
        while true {
            DispatchQueue.main.async {
                lock.lock()
                lastAnswer = HostClock.nowNanos()
                lock.unlock()
            }
            Thread.sleep(forTimeInterval: 0.25)
            lock.lock()
            let answered = lastAnswer
            lock.unlock()
            let now = HostClock.nowNanos()
            if now - answered > 1_000_000_000 {
                if hungSince == nil {
                    hungSince = answered
                    log.error("the main thread has not answered for over a second")
                }
            } else if let since = hungSince {
                hungSince = nil
                log.error("the main thread answers again after \(Double(answered - since) / 1e9, format: .fixed(precision: 1)) s")
            }
        }
    }
}
