import Foundation

/// The viewer's jitter buffer for sound: decoded stereo frames wait here
/// until the output device asks for them.
///
/// Packets arrive in bursts (the host's capture device hands over about
/// 10 ms at a time, the network adds jitter), while the output device pulls
/// at a steady rate. Playback starts once `targetFrames` are buffered. When
/// the buffer runs dry it waits to refill, and if sound resumes within
/// `pauseThreshold` the target grows, so a link with more jitter gets more
/// margin. A longer gap is the host pausing: Core Audio stops capturing
/// while nothing it taps plays, and that says nothing about the network. After a long stretch without one the
/// target shrinks again. When the buffer holds clearly more than the target
/// for a while (the two Macs' clocks differ a little, or a burst arrived after
/// a stall), the oldest frames are dropped to bring the delay back down.
public struct AudioPlayoutBuffer: Sendable {
    public struct Configuration: Sendable {
        public var sampleRate: Double = 48_000
        public var initialTarget: Double = 0.030
        public var minimumTarget: Double = 0.020
        public var maximumTarget: Double = 0.200
        /// Added to the target after an underrun.
        public var growth: Double = 0.010
        /// Taken off the target after `shrinkAfter` seconds without an underrun.
        public var shrink: Double = 0.005
        public var shrinkAfter: Double = 20
        /// A gap longer than this is a pause in the sound, not an underrun.
        public var pauseThreshold: Double = 0.25
        /// More than this above the target, for `excessPatience`, gets trimmed.
        public var excessAllowance: Double = 0.030
        public var excessPatience: Double = 0.5
        public var capacity: Double = 1.0

        public init() {}
    }

    public let configuration: Configuration
    private let channels = 2
    private var ring: [Float]
    private var readFrame = 0
    public private(set) var bufferedFrames = 0
    public private(set) var targetFrames: Int
    private var buffering = true
    private var framesSinceUnderrun = 0
    private var framesOverTarget = 0
    /// Since running dry, while waiting to tell an underrun from a pause.
    private var starvedFrames: Int?

    public private(set) var underruns = 0
    /// Gaps in the sound itself.
    public private(set) var pauses = 0
    /// Frames thrown away to keep the delay down (or because the buffer was full).
    public private(set) var droppedFrames = 0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        ring = [Float](repeating: 0, count: Int(configuration.capacity * configuration.sampleRate) * channels)
        targetFrames = Self.frames(configuration.initialTarget, configuration)
    }

    private static func frames(_ seconds: Double, _ configuration: Configuration) -> Int {
        Int(seconds * configuration.sampleRate)
    }

    private func frames(_ seconds: Double) -> Int { Self.frames(seconds, configuration) }

    private var capacityFrames: Int { ring.count / channels }

    public var isBuffering: Bool { buffering }

    /// Appends interleaved stereo frames.
    public mutating func write(_ samples: UnsafeBufferPointer<Float>) {
        if let starved = starvedFrames {
            starvedFrames = nil
            if starved <= frames(configuration.pauseThreshold) {
                underruns += 1
                targetFrames = min(frames(configuration.maximumTarget), targetFrames + frames(configuration.growth))
            } else {
                pauses += 1
            }
        }
        var count = samples.count / channels
        var source = 0
        if count > capacityFrames {
            source = (count - capacityFrames) * channels
            droppedFrames += count - capacityFrames
            count = capacityFrames
        }
        let overflow = bufferedFrames + count - capacityFrames
        if overflow > 0 { discard(overflow) }
        var writeFrame = (readFrame + bufferedFrames) % capacityFrames
        var remaining = count
        while remaining > 0 {
            let run = min(remaining, capacityFrames - writeFrame)
            ring.withUnsafeMutableBufferPointer { ring in
                (ring.baseAddress! + writeFrame * channels)
                    .update(from: samples.baseAddress! + source, count: run * channels)
            }
            source += run * channels
            remaining -= run
            writeFrame = (writeFrame + run) % capacityFrames
        }
        bufferedFrames += count
    }

    /// Appends silence in place of lost frames.
    public mutating func writeSilence(frames count: Int) {
        let zeros = [Float](repeating: 0, count: min(count, capacityFrames) * channels)
        zeros.withUnsafeBufferPointer { write($0) }
    }

    private mutating func discard(_ count: Int) {
        let count = min(count, bufferedFrames)
        readFrame = (readFrame + count) % capacityFrames
        bufferedFrames -= count
        droppedFrames += count
    }

    /// Fills `count` frames of the two output channels; silence where there
    /// is nothing to play. Returns how many frames were real sound.
    @discardableResult
    public mutating func read(frames count: Int, left: UnsafeMutablePointer<Float>,
                              right: UnsafeMutablePointer<Float>) -> Int {
        framesSinceUnderrun += count
        if framesSinceUnderrun > frames(configuration.shrinkAfter) {
            framesSinceUnderrun = 0
            targetFrames = max(frames(configuration.minimumTarget), targetFrames - frames(configuration.shrink))
        }
        if buffering {
            guard bufferedFrames >= targetFrames else {
                if let starved = starvedFrames { starvedFrames = starved + count }
                left.update(repeating: 0, count: count)
                right.update(repeating: 0, count: count)
                return 0
            }
            buffering = false
        }
        trimExcess(count: count)
        let available = min(count, bufferedFrames)
        var frame = readFrame
        ring.withUnsafeBufferPointer { ring in
            for index in 0..<available {
                left[index] = ring[frame * channels]
                right[index] = ring[frame * channels + 1]
                frame += 1
                if frame == capacityFrames { frame = 0 }
            }
        }
        readFrame = frame
        bufferedFrames -= available
        if available < count {
            left.advanced(by: available).update(repeating: 0, count: count - available)
            right.advanced(by: available).update(repeating: 0, count: count - available)
            buffering = true
            framesSinceUnderrun = 0
            starvedFrames = count - available
        }
        return available
    }

    private mutating func trimExcess(count: Int) {
        // Measured after this read takes its share, so the device's own
        // buffer size doesn't count as excess.
        let excess = bufferedFrames - count - targetFrames
        guard excess > frames(configuration.excessAllowance) else {
            framesOverTarget = 0
            return
        }
        framesOverTarget += count
        guard framesOverTarget >= frames(configuration.excessPatience) else { return }
        framesOverTarget = 0
        discard(excess)
    }
}
