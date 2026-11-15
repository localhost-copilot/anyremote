import CoreMedia
import Foundation
import Darwin

/// Monotonic host time in nanoseconds, the same clock domain ScreenCaptureKit
/// and Core Animation timestamps use (mach absolute time).
public enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public static func nowNanos() -> UInt64 {
        nanos(fromMachTime: mach_absolute_time())
    }

    public static func nanos(fromMachTime time: UInt64) -> UInt64 {
        time * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    /// Converts a CMTime on the host time clock to nanoseconds.
    public static func nanos(from time: CMTime) -> UInt64 {
        guard time.isValid, time.isNumeric, time.value >= 0 else { return 0 }
        return UInt64(CMTimeConvertScale(time, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value)
    }

    /// Converts a CACurrentMediaTime-style seconds value to nanoseconds.
    public static func nanos(fromSeconds seconds: Double) -> UInt64 {
        seconds > 0 ? UInt64(seconds * 1_000_000_000) : 0
    }
}

/// Maps sender timestamps into this machine's host clock.
///
/// In loopback the mapping is the identity. Across machines it is the offset
/// estimated by ping/pong clock sync; until the first estimate arrives,
/// cross-clock stages are not recorded.
public final class RemoteClock: @unchecked Sendable {
    private let lock = NSLock()
    /// sender − local, in nanoseconds.
    private var offsetNanos: Int64?

    public init(offsetNanos: Int64? = nil) {
        self.offsetNanos = offsetNanos
    }

    public static func local() -> RemoteClock { RemoteClock(offsetNanos: 0) }

    public func update(offsetNanos: Int64) {
        lock.lock()
        self.offsetNanos = offsetNanos
        lock.unlock()
    }

    public func localTime(fromSender nanos: UInt64) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard let offsetNanos, nanos > 0 else { return nil }
        return UInt64(bitPattern: Int64(bitPattern: nanos) &- offsetNanos)
    }
}
