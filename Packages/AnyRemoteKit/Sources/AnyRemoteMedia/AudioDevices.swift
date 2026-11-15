import AudioToolbox
import CoreAudio
import Foundation
import os

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Audio")

/// Core Audio device lookups.
public enum AudioDevices {
    public static func address(_ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// The device with this UID, if present.
    public static func device(uid: String) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var uid = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &uid) { qualifier in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), qualifier, &size, &device)
        }
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    public static func uid(of device: AudioObjectID) -> String? {
        var address = address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    public static var defaultInput: AudioObjectID? {
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size,
                                         &device) == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    @discardableResult
    public static func setDefaultInput(_ device: AudioObjectID) -> Bool {
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        var device = device
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                          UInt32(MemoryLayout<AudioObjectID>.size), &device) == noErr
    }

    public static func nominalSampleRate(_ device: AudioObjectID) -> Double? {
        var address = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }

    public static func uint32(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector,
                              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = address(selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    /// Asks for `frames` per I/O cycle; the device may round it.
    static func setBufferFrameSize(_ device: AudioObjectID, _ frames: UInt32) {
        var address = address(kAudioDevicePropertyBufferFrameSize)
        var value = frames
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    static func error(_ status: OSStatus, _ action: String) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Could not \(action) (\(status))."])
    }
}

/// Plays the playout buffer into one output device directly, mixed down to
/// as many channels as it has: the AnyRemote Microphone's feed takes one.
/// An I/O proc of our own rather than an AVAudioEngine keeps the delay to a
/// single small I/O buffer.
final class DeviceAudioOutput: AudioSink, @unchecked Sendable {
    private static let ioFrames: UInt32 = 240
    private let device: AudioObjectID
    private var ioProc: AudioDeviceIOProcID?
    private let left = UnsafeMutablePointer<Float>.allocate(capacity: 16_384)
    private let right = UnsafeMutablePointer<Float>.allocate(capacity: 16_384)
    let outputLatency: Double

    init(uid: String, playout: SharedPlayout) throws {
        guard let device = AudioDevices.device(uid: uid) else {
            throw AudioDevices.error(kAudioHardwareBadDeviceError, "find the sound device \(uid)")
        }
        self.device = device
        AudioDevices.setBufferFrameSize(device, Self.ioFrames)
        let rate = AudioDevices.nominalSampleRate(device) ?? AudioWireFormat.sampleRate
        let frames = AudioDevices.uint32(device, kAudioDevicePropertyBufferFrameSize) ?? Self.ioFrames
        let latency = (AudioDevices.uint32(device, kAudioDevicePropertyLatency, scope: kAudioObjectPropertyScopeOutput) ?? 0)
            + (AudioDevices.uint32(device, kAudioDevicePropertySafetyOffset, scope: kAudioObjectPropertyScopeOutput) ?? 0)
        outputLatency = Double(frames + latency) / rate
        let left = left
        let right = right
        var ioProc: AudioDeviceIOProcID?
        let created = AudioDeviceCreateIOProcIDWithBlock(&ioProc, device, nil) { _, _, _, output, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(output) {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self), buffer.mNumberChannels > 0 else {
                    continue
                }
                let channels = Int(buffer.mNumberChannels)
                let count = min(16_384, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels)
                playout.read(frames: count, left: left, right: right)
                for frame in 0..<count {
                    if channels == 1 {
                        data[frame] = (left[frame] + right[frame]) * 0.5
                    } else {
                        data[frame * channels] = left[frame]
                        data[frame * channels + 1] = right[frame]
                        for extra in 2..<max(2, channels) { data[frame * channels + extra] = 0 }
                    }
                }
                // One buffer carries the stream; more would read the playout twice.
                break
            }
        }
        guard created == noErr, let ioProc else {
            left.deallocate()
            right.deallocate()
            throw AudioDevices.error(created, "play into the sound device")
        }
        self.ioProc = ioProc
        let started = AudioDeviceStart(device, ioProc)
        guard started == noErr else {
            AudioDeviceDestroyIOProcID(device, ioProc)
            self.ioProc = nil
            left.deallocate()
            right.deallocate()
            throw AudioDevices.error(started, "start the sound device")
        }
        log.notice("playing into \(uid, privacy: .public) at \(rate) Hz, \(frames) frames per cycle")
    }

    func stop() {
        guard let ioProc else { return }
        AudioDeviceStop(device, ioProc)
        AudioDeviceDestroyIOProcID(device, ioProc)
        self.ioProc = nil
        left.deallocate()
        right.deallocate()
    }
}

/// Records this Mac's default input device (its microphone) and hands on
/// interleaved stereo frames, the mono microphone in both channels. It
/// follows the default input when it changes (a headset plugged in).
///
/// A device I/O proc rather than an AVAudioEngine tap, because taps deliver
/// about 100 ms at a time, which would all be delay.
public final class MicrophoneCapture: @unchecked Sendable {
    public typealias Handler = @Sendable (_ frames: UnsafeBufferPointer<Float>, _ sampleRate: Double,
                                          _ hostNanos: UInt64) -> Void
    private static let ioFrames: UInt32 = 240
    private static let maximumFrames = 16_384
    /// The AnyRemote Microphone itself: never recorded, or a Mac that both
    /// controls and is controlled would hear itself in a loop.
    private static let ownMicrophoneUID = "com.localhost-copilot.anyremote.microphone"
    /// Development (`ANYREMOTE_MICROPHONE_TONE=1`): a 440 Hz tone with a
    /// 5 ms click at every whole second of the host clock, instead of the
    /// microphone, so the delay to the other Mac's recording apps can be
    /// measured in loopback, where both share one clock.
    public static let testTone = ProcessInfo.processInfo.environment["ANYREMOTE_MICROPHONE_TONE"] == "1"

    private let queue = DispatchQueue(label: "anyremote.microphone.capture", qos: .userInitiated)
    private let handler: Handler
    private let mix = UnsafeMutablePointer<Float>.allocate(capacity: maximumFrames * 2)

    // Queue-confined.
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var defaultListener: AudioObjectPropertyListenerBlock?
    private var stopped = false
    private var toneTimer: DispatchSourceTimer?

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    deinit {
        mix.deallocate()
    }

    public func start() throws {
        try queue.sync {
            if Self.testTone {
                startTone()
                return
            }
            try open()
            var address = AudioDevices.address(kAudioHardwarePropertyDefaultInputDevice)
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.defaultInputChanged() }
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
            defaultListener = listener
        }
    }

    public func stop() {
        queue.sync {
            guard !stopped else { return }
            stopped = true
            if let defaultListener {
                var address = AudioDevices.address(kAudioHardwarePropertyDefaultInputDevice)
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue,
                                                       defaultListener)
            }
            defaultListener = nil
            toneTimer?.cancel()
            toneTimer = nil
            close()
        }
    }

    private func startTone() {
        let rate = AudioWireFormat.sampleRate
        let start = HostClock.nowNanos()
        var produced = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        timer.setEventHandler { [handler, mix] in
            let due = Int(Double(HostClock.nowNanos() - start) / 1e9 * rate)
            let frames = min(Self.maximumFrames, due - produced)
            guard frames > 0 else { return }
            let firstNanos = start + UInt64(Double(produced) / rate * 1e9)
            for index in 0..<frames {
                let nanos = firstNanos + UInt64(Double(index) / rate * 1e9)
                let sample: Float = nanos % 1_000_000_000 < 5_000_000
                    ? 0.9 : Float(sin(Double(produced + index) * 2 * .pi * 440 / rate) * 0.1)
                mix[index * 2] = sample
                mix[index * 2 + 1] = sample
            }
            produced += frames
            handler(UnsafeBufferPointer(start: mix, count: frames * 2), rate, firstNanos)
        }
        timer.resume()
        toneTimer = timer
        log.notice("sending a test tone instead of the microphone")
    }

    private func defaultInputChanged() {
        guard !stopped, AudioDevices.defaultInput != device else { return }
        log.notice("microphone changed; reopening")
        close()
        do { try open() } catch {
            log.error("microphone reopen failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func open() throws {
        guard let device = AudioDevices.defaultInput,
              AudioDevices.uid(of: device) != Self.ownMicrophoneUID else {
            throw AudioDevices.error(kAudioHardwareBadDeviceError, "find a microphone")
        }
        self.device = device
        AudioDevices.setBufferFrameSize(device, Self.ioFrames)
        let rate = AudioDevices.nominalSampleRate(device) ?? AudioWireFormat.sampleRate
        let handler = handler
        let mix = mix
        var ioProc: AudioDeviceIOProcID?
        let created = AudioDeviceCreateIOProcIDWithBlock(&ioProc, device, nil) { _, input, inputTime, _, _ in
            Self.render(input, time: inputTime, rate: rate, mix: mix, handler: handler)
        }
        guard created == noErr, let ioProc else { throw AudioDevices.error(created, "read the microphone") }
        let started = AudioDeviceStart(device, ioProc)
        guard started == noErr else {
            AudioDeviceDestroyIOProcID(device, ioProc)
            throw AudioDevices.error(started, "start the microphone")
        }
        self.ioProc = ioProc
        log.notice("microphone \(AudioDevices.uid(of: device) ?? "?", privacy: .public) open at \(rate) Hz")
    }

    private func close() {
        if let ioProc {
            AudioDeviceStop(device, ioProc)
            AudioDeviceDestroyIOProcID(device, ioProc)
        }
        ioProc = nil
        device = AudioObjectID(kAudioObjectUnknown)
    }

    /// The first channel of the first input stream, in both output channels:
    /// microphones are mono, and a multichannel interface's first input is
    /// the one a single microphone is plugged into.
    private static func render(_ input: UnsafePointer<AudioBufferList>, time: UnsafePointer<AudioTimeStamp>,
                               rate: Double, mix: UnsafeMutablePointer<Float>, handler: Handler) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let buffer = buffers.first(where: { $0.mNumberChannels > 0 && $0.mData != nil }),
              let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
        let channels = Int(buffer.mNumberChannels)
        let frames = min(maximumFrames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels)
        guard frames > 0 else { return }
        for frame in 0..<frames {
            let sample = data[frame * channels]
            mix[frame * 2] = sample
            mix[frame * 2 + 1] = sample
        }
        let hostNanos = time.pointee.mFlags.contains(.hostTimeValid)
            ? HostClock.nanos(fromMachTime: time.pointee.mHostTime) : HostClock.nowNanos()
        handler(UnsafeBufferPointer(start: mix, count: frames * 2), rate, hostNanos)
    }
}
