import Foundation

/// Rolling per-stage latency and throughput statistics for one stream.
///
/// Stage intervals are only recorded between timestamps of the same clock
/// domain. In loopback every stage shares the host clock; across machines the
/// sender reports its own stages separately.
public final class PipelineStats: @unchecked Sendable {
    public enum Stage: String, CaseIterable, Sendable {
        /// SCK presentation time → frame handed to us.
        case capture
        /// Frame handed to us → submitted to the encoder (waiting for the busy encoder).
        case encodeWait = "wait"
        /// Submitted → encoder output.
        case encode
        /// Reassembled → decoder output.
        case decode
        /// Decoder output → physically presented.
        case present
        /// SCK presentation time → reassembled on the receiver (loopback only).
        case receive
        /// SCK presentation time → physically presented (loopback only).
        case total
    }

    public struct Summary: Sendable, CustomStringConvertible {
        public var p50: [Stage: Double] = [:]
        public var p95: [Stage: Double] = [:]
        public var framesPerSecond: Double = 0
        public var megabitsPerSecond: Double = 0
        public var keyframes: Int = 0
        public var droppedFrames: Int = 0
        public var pixelSize: (width: Int, height: Int) = (0, 0)

        public var description: String {
            var parts = [String(format: "%dx%d %.1ffps %.1fMbps key=%d drop=%d",
                                pixelSize.width, pixelSize.height, framesPerSecond, megabitsPerSecond,
                                keyframes, droppedFrames)]
            for stage in Stage.allCases {
                guard let p50 = p50[stage], let p95 = p95[stage] else { continue }
                parts.append(String(format: "%@ %.2f/%.2f", stage.rawValue, p50, p95))
            }
            return parts.joined(separator: "  ")
        }
    }

    private let lock = NSLock()
    private var samples: [Stage: [Double]] = [:]
    private var frames = 0
    private var bytes = 0
    private var keyframes = 0
    private var dropped = 0
    private var pixelSize: (Int, Int) = (0, 0)
    private var windowStart = HostClock.nowNanos()

    public init() {}

    public func record(_ stage: Stage, from start: UInt64, to end: UInt64) {
        guard start > 0, end >= start else { return }
        let milliseconds = Double(end - start) / 1_000_000
        lock.lock()
        samples[stage, default: []].append(milliseconds)
        lock.unlock()
    }

    public func recordFrame(bytes count: Int, keyframe: Bool, width: Int, height: Int) {
        lock.lock()
        frames += 1
        bytes += count
        if keyframe { keyframes += 1 }
        pixelSize = (width, height)
        lock.unlock()
    }

    public func recordDropped(_ count: Int) {
        lock.lock()
        dropped += count
        lock.unlock()
    }

    /// Returns the summary since the previous call and starts a new window.
    public func drain() -> Summary {
        lock.lock()
        let now = HostClock.nowNanos()
        let seconds = max(Double(now - windowStart) / 1_000_000_000, 0.001)
        var summary = Summary()
        for (stage, values) in samples where !values.isEmpty {
            let sorted = values.sorted()
            summary.p50[stage] = sorted[sorted.count / 2]
            summary.p95[stage] = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        }
        summary.framesPerSecond = Double(frames) / seconds
        summary.megabitsPerSecond = Double(bytes) * 8 / seconds / 1_000_000
        summary.keyframes = keyframes
        summary.droppedFrames = dropped
        summary.pixelSize = pixelSize
        samples.removeAll(keepingCapacity: true)
        frames = 0
        bytes = 0
        keyframes = 0
        dropped = 0
        windowStart = now
        lock.unlock()
        return summary
    }
}
