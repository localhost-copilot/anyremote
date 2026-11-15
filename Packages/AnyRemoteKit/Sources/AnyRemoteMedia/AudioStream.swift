import AnyRemoteWire
@preconcurrency import AVFAudio
import Foundation
import os

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Audio")

/// Host side of a sound stream: captured PCM → 48 kHz → AAC-ELD → packets.
public final class AudioStreamSender: @unchecked Sendable {
    public let format: AudioStreamFormat
    private let queue = DispatchQueue(label: "anyremote.audio.encode", qos: .userInteractive)
    private let send: @Sendable (Data) -> Void

    // Queue-confined.
    private let encoder: AACELDEncoder
    private var resampler: AudioResampler?
    /// 48 kHz interleaved frames waiting for a full packet.
    private var pending: [Float] = []
    /// When `pending`'s first frame was captured (host clock).
    private var pendingStartNanos: UInt64 = 0
    private var sequence: UInt32 = 0
    private var previous: Data?

    public init(send: @escaping @Sendable (Data) -> Void) throws {
        encoder = try AACELDEncoder()
        format = encoder.format
        self.send = send
        pending.reserveCapacity(8192)
    }

    /// Thread-safe (called on the capture device's I/O thread): copies
    /// `frames`, interleaved stereo at `sampleRate`, first captured at `hostNanos`.
    public func submit(_ frames: UnsafeBufferPointer<Float>, sampleRate: Double, hostNanos: UInt64) {
        let copy = Array(frames)
        queue.async { [self] in
            copy.withUnsafeBufferPointer { append($0, sampleRate: sampleRate, hostNanos: hostNanos) }
        }
    }

    /// Waits until everything submitted so far is encoded and sent.
    func flushForTesting() {
        queue.sync {}
    }

    private func append(_ frames: UnsafeBufferPointer<Float>, sampleRate: Double, hostNanos: UInt64) {
        let channels = Int(AudioWireFormat.channels)
        let before = pending.count / channels
        if sampleRate == AudioWireFormat.sampleRate {
            pending.append(contentsOf: frames)
        } else {
            if resampler?.sourceRate != sampleRate {
                resampler = AudioResampler(sourceRate: sampleRate)
                log.notice("resampling sound from \(sampleRate) Hz")
            }
            guard let resampler else { return }
            var offset = 0
            while offset < frames.count {
                let count = min(frames.count - offset, resampler.maximumFrames * channels)
                resampler.convert(UnsafeBufferPointer(rebasing: frames[offset..<(offset + count)])) {
                    pending.append(contentsOf: $0)
                }
                offset += count
            }
        }
        // Anchor on the newest capture time: what was pending came just before it.
        let pendingNanos = UInt64(Double(before) / AudioWireFormat.sampleRate * 1e9)
        pendingStartNanos = hostNanos > pendingNanos ? hostNanos - pendingNanos : hostNanos
        let packetSamples = AudioWireFormat.framesPerPacket * channels
        var consumed = 0
        while pending.count - consumed >= packetSamples {
            let unit: Data?
            do {
                unit = try pending.withUnsafeBufferPointer {
                    try encoder.encode(UnsafeBufferPointer(rebasing: $0[consumed..<(consumed + packetSamples)]))
                }
            } catch {
                log.error("sound encode failed: \(String(describing: error), privacy: .public)")
                unit = nil
            }
            consumed += packetSamples
            let captured = pendingStartNanos
            pendingStartNanos += UInt64(Double(AudioWireFormat.framesPerPacket) / AudioWireFormat.sampleRate * 1e9)
            guard let unit else { continue }
            let packet = AudioPacket(sequence: sequence, captureNanos: captured, accessUnit: unit,
                                     previousAccessUnit: previous)
            sequence &+= 1
            previous = unit
            if let datagram = try? packet.serialized() { send(datagram) }
        }
        pending.removeFirst(consumed)
    }
}

/// The playout buffer behind a lock, shared by the decoder queue (writing)
/// and the output device's render thread (reading).
final class SharedPlayout: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<AudioPlayoutBuffer>

    init(configuration: AudioPlayoutBuffer.Configuration) {
        lock = OSAllocatedUnfairLock(initialState: AudioPlayoutBuffer(configuration: configuration))
    }

    func write(_ samples: UnsafeBufferPointer<Float>) {
        lock.withLockUnchecked { $0.write(samples) }
    }

    func writeSilence(frames: Int) {
        lock.withLock { $0.writeSilence(frames: frames) }
    }

    func read(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) -> Int {
        lock.withLockUnchecked { $0.read(frames: frames, left: left, right: right) }
    }

    func snapshot() -> (buffered: Int, target: Int, underruns: Int, pauses: Int, dropped: Int) {
        lock.withLock { ($0.bufferedFrames, $0.targetFrames, $0.underruns, $0.pauses, $0.droppedFrames) }
    }
}

/// Plays the playout buffer on the default output device.
final class AudioOutput: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?

    init(playout: SharedPlayout) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: AudioWireFormat.sampleRate,
                                   channels: AudioWireFormat.channels)!
        let source = AVAudioSourceNode(format: format) { isSilence, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            if playout.read(frames: Int(frameCount), left: left, right: right) == 0 { isSilence.pointee = true }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        // A new output device (headphones, AirPlay) stops the engine.
        let engine = engine
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in
            log.notice("sound output changed; restarting")
            engine.prepare()
            do { try engine.start() } catch {
                log.error("sound output restart failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Seconds from rendering a frame to hearing it.
    var outputLatency: Double { engine.outputNode.presentationLatency + engine.outputNode.outputPresentationLatency }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.stop()
    }
}

/// Viewer side of a sound stream: packets → AAC-ELD decode → playout buffer
/// → the output device.
public final class AudioStreamReceiver: @unchecked Sendable {
    public struct Report: Sendable, CustomStringConvertible {
        public var packets = 0
        /// Lost packets filled in from the next packet's copy.
        public var recovered = 0
        /// Lost packets played as silence.
        public var concealed = 0
        public var late = 0
        /// Since playback began (the rest count since the last report).
        public var underruns = 0
        /// Since playback began: gaps because the host's sound paused.
        public var pauses = 0
        /// Since playback began: sound skipped to keep the delay down.
        public var droppedMilliseconds = 0.0
        public var bufferedMilliseconds = 0.0
        public var targetMilliseconds = 0.0
        /// Host capture → arrival here (median), when the clocks are synced.
        public var transitMilliseconds: Double?
        public var outputMilliseconds = 0.0
        /// The loudest sample received, in dBFS (-inf for silence).
        public var peakDecibels = -Double.infinity

        /// Capture on the host to sound from this Mac's speakers.
        public var totalMilliseconds: Double? {
            transitMilliseconds.map { $0 + bufferedMilliseconds + outputMilliseconds }
        }

        public var description: String {
            func ms(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "-" }
            return "audio packets=\(packets) recovered=\(recovered) concealed=\(concealed) late=\(late) "
                + "underruns=\(underruns) pauses=\(pauses) dropped=\(ms(droppedMilliseconds))ms buffer=\(ms(bufferedMilliseconds))ms "
                + "target=\(ms(targetMilliseconds))ms transit=\(ms(transitMilliseconds))ms "
                + "output=\(ms(outputMilliseconds))ms total=\(ms(totalMilliseconds))ms "
                + "peak=\(peakDecibels.isFinite ? String(format: "%.0f", peakDecibels) : "-inf")dB"
        }
    }

    /// Development: the starting jitter buffer, in milliseconds.
    private static let bufferOverride = Double(ProcessInfo.processInfo.environment["ANYREMOTE_AUDIO_BUFFER_MS"] ?? "")

    public var remoteClock: RemoteClock?
    private let queue = DispatchQueue(label: "anyremote.audio.decode", qos: .userInteractive)
    private let playout: SharedPlayout
    private let framesPerPacket: Int

    // Queue-confined.
    private let decoder: AACELDDecoder
    private var output: AudioOutput?
    private var lastSequence: UInt32?
    private var report = Report()
    private var transits: [Double] = []
    private var peak: Float = 0
    private var closed = false

    public init(format: AudioStreamFormat) throws {
        decoder = try AACELDDecoder(format: format)
        framesPerPacket = format.framesPerPacket
        var configuration = AudioPlayoutBuffer.Configuration()
        if let override = Self.bufferOverride {
            configuration.initialTarget = override / 1000
            configuration.minimumTarget = min(configuration.minimumTarget, override / 1000)
        }
        playout = SharedPlayout(configuration: configuration)
        // Starting the engine takes a moment; packets queue up behind it.
        queue.async { [self] in
            guard !closed else { return }
            do {
                output = try AudioOutput(playout: playout)
            } catch {
                log.error("sound output failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Thread-safe. `datagram` is an opened `AudioPacket` datagram.
    public func receive(_ datagram: Data) {
        let arrived = HostClock.nowNanos()
        queue.async { [self] in
            guard !closed, let packet = try? AudioPacket.parse(datagram) else { return }
            process(packet, arrived: arrived)
        }
    }

    private func process(_ packet: AudioPacket, arrived: UInt64) {
        if let last = lastSequence {
            let delta = Int32(bitPattern: packet.sequence &- last)
            guard delta > 0 else {
                report.late += 1
                return
            }
            // Up to half a second of loss is filled in; longer, the stream
            // simply resumes (the buffer has run dry and refills).
            if delta > 1, delta <= 50 {
                var missing = Int(delta) - 1
                if let previous = packet.previousAccessUnit {
                    missing -= 1
                    if missing > 0 { conceal(missing) }
                    decode(previous)
                    report.recovered += 1
                } else {
                    conceal(missing)
                }
            }
        }
        lastSequence = packet.sequence
        report.packets += 1
        if let captured = remoteClock?.localTime(fromSender: packet.captureNanos), arrived > captured {
            transits.append(Double(arrived - captured) / 1e6)
        }
        decode(packet.accessUnit)
    }

    private func conceal(_ packets: Int) {
        report.concealed += packets
        playout.writeSilence(frames: packets * framesPerPacket)
    }

    private func decode(_ accessUnit: Data) {
        do {
            try decoder.decode(accessUnit) { samples in
                for sample in samples { peak = max(peak, abs(sample)) }
                playout.write(samples)
            }
        } catch {
            playout.writeSilence(frames: framesPerPacket)
        }
    }

    /// Statistics since the last call.
    public func takeReport() -> Report {
        queue.sync {
            var current = report
            let state = playout.snapshot()
            let rate = AudioWireFormat.sampleRate
            current.underruns = state.underruns
            current.pauses = state.pauses
            current.droppedMilliseconds = Double(state.dropped) / rate * 1000
            current.bufferedMilliseconds = Double(state.buffered) / rate * 1000
            current.targetMilliseconds = Double(state.target) / rate * 1000
            current.outputMilliseconds = (output?.outputLatency ?? 0) * 1000
            if !transits.isEmpty {
                current.transitMilliseconds = transits.sorted()[transits.count / 2]
            }
            transits.removeAll(keepingCapacity: true)
            current.peakDecibels = peak > 0 ? 20 * log10(Double(peak)) : -.infinity
            peak = 0
            report = Report()
            return current
        }
    }

    public func close() {
        queue.async { [self] in
            closed = true
            output?.stop()
            output = nil
        }
    }
}
