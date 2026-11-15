import AnyRemoteMedia
import AudioToolbox
import CoreAudio
import Foundation
import os

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "AudioTap")

/// The process that macOS holds responsible for `pid`: the app behind a
/// helper, for instance Safari for its `com.apple.WebKit.GPU` process.
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsiblePID(for pid: pid_t) -> pid_t

/// Whose sound a viewer hears.
enum AudioScope: Equatable, Sendable {
    /// These apps (by process ID) and the helpers that play sound for them.
    case applications(Set<pid_t>)
    /// Everything except AnyRemote itself.
    case system
}

/// Captures the sound of an `AudioScope` with Core Audio process taps.
///
/// Sound has no window: macOS mixes it per process, so a window's sound is
/// its app's. Browsers and WebKit apps play from helper processes (Chrome's
/// audio service, one WebKit GPU process per app), so every audio process
/// whose responsible process is in the scope is tapped too.
///
/// Each process gets its own tap, and all of them feed one private aggregate
/// device whose input this mixes. A tap's process list cannot be changed
/// once created (Core Audio answers `'!hog'`), but the device's tap list
/// can, in about 17 ms and without a gap, so processes that start or stop
/// playing sound are followed live. An empty tap stays in the list so the
/// device keeps running (and keeps sending silence) with nothing to hear.
final class ProcessAudioTap: @unchecked Sendable {
    typealias Handler = @Sendable (_ frames: UnsafeBufferPointer<Float>, _ sampleRate: Double, _ hostNanos: UInt64) -> Void

    private enum TapKey: Hashable {
        case process(AudioObjectID)
        case system(excluding: [AudioObjectID])
    }

    private struct Tap {
        var id: AudioObjectID
        var uid: String
    }

    private let queue = DispatchQueue(label: "anyremote.audio.tap", qos: .userInitiated)
    private let handler: Handler
    private let render: RenderState

    // Queue-confined.
    private var scope: AudioScope
    private var mutes: Bool
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var anchor: Tap?
    private var taps: [TapKey: Tap] = [:]
    private var processListener: AudioObjectPropertyListenerBlock?
    private var rateListener: AudioObjectPropertyListenerBlock?
    private var stopped = false

    /// `mutes`: the tapped processes go quiet on this Mac while tapped.
    init(scope: AudioScope, mutes: Bool, handler: @escaping Handler) {
        self.scope = scope
        self.mutes = mutes
        self.handler = handler
        render = RenderState()
    }

    deinit {
        render.release()
    }

    func start() throws {
        try queue.sync { try startOnQueue() }
    }

    func update(scope: AudioScope, mutes: Bool) {
        queue.async { [self] in
            guard !stopped, scope != self.scope || mutes != self.mutes else { return }
            let remute = mutes != self.mutes
            self.scope = scope
            self.mutes = mutes
            if remute { replaceAllTaps() } else { refresh() }
        }
    }

    func stop() {
        queue.sync {
            guard !stopped else { return }
            stopped = true
            tearDown()
        }
    }

    // MARK: Device

    private func startOnQueue() throws {
        let anchor = try Self.makeTap(processes: [], exclusive: false, mutes: false)
        self.anchor = anchor
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AnyRemote Sound",
            kAudioAggregateDeviceUIDKey: "com.localhost-copilot.anyremote.sound.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: anchor.uid, kAudioSubTapDriftCompensationKey: true]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &device)
        guard status == noErr else {
            tearDown()
            throw Self.error(status, "create the sound capture device")
        }
        self.device = device
        render.sampleRate = Self.nominalSampleRate(device)
        Self.setBufferFrameSize(device, Self.ioFrames)
        refresh()

        let render = render
        let handler = handler
        var ioProc: AudioDeviceIOProcID?
        let created = AudioDeviceCreateIOProcIDWithBlock(&ioProc, device, nil) { _, input, inputTime, _, _ in
            render.process(input, time: inputTime, handler: handler)
        }
        guard created == noErr, let ioProc else {
            tearDown()
            throw Self.error(created, "read the sound capture device")
        }
        self.ioProc = ioProc
        let started = AudioDeviceStart(device, ioProc)
        guard started == noErr else {
            tearDown()
            throw Self.error(started, "start sound capture")
        }

        var processes = Self.address(kAudioHardwarePropertyProcessObjectList)
        let processListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &processes, queue, processListener)
        self.processListener = processListener
        var rate = Self.address(kAudioDevicePropertyNominalSampleRate)
        let rateListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.device != kAudioObjectUnknown else { return }
            self.render.sampleRate = Self.nominalSampleRate(self.device)
        }
        AudioObjectAddPropertyListenerBlock(device, &rate, queue, rateListener)
        self.rateListener = rateListener
        log.notice("sound capture started at \(self.render.sampleRate) Hz")
    }

    private func tearDown() {
        if let processListener {
            var address = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue,
                                                   processListener)
        }
        processListener = nil
        if let rateListener, device != kAudioObjectUnknown {
            var address = Self.address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(device, &address, queue, rateListener)
        }
        rateListener = nil
        if let ioProc {
            AudioDeviceStop(device, ioProc)
            AudioDeviceDestroyIOProcID(device, ioProc)
        }
        ioProc = nil
        if device != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(device) }
        device = AudioObjectID(kAudioObjectUnknown)
        for tap in taps.values { AudioHardwareDestroyProcessTap(tap.id) }
        taps.removeAll()
        if let anchor { AudioHardwareDestroyProcessTap(anchor.id) }
        anchor = nil
    }

    // MARK: Taps

    /// Brings the taps in line with the scope and the processes playing now.
    private func refresh() {
        guard !stopped, device != kAudioObjectUnknown else { return }
        let wanted = wantedKeys()
        let current = Set(taps.keys)
        guard wanted != current else { return }
        var removed: [Tap] = []
        for key in current.subtracting(wanted) {
            if let tap = taps.removeValue(forKey: key) { removed.append(tap) }
        }
        for key in wanted.subtracting(current) {
            do {
                taps[key] = switch key {
                case .process(let object): try Self.makeTap(processes: [object], exclusive: false, mutes: mutes)
                case .system(let excluded): try Self.makeTap(processes: excluded, exclusive: true, mutes: mutes)
                }
            } catch {
                log.error("\(error.localizedDescription, privacy: .public)")
            }
        }
        setTapList()
        // Only once the device has let go of them.
        for tap in removed { AudioHardwareDestroyProcessTap(tap.id) }
        log.notice("tapping \(self.taps.count) sound source(s)")
    }

    private func replaceAllTaps() {
        let old = Array(taps.values)
        taps.removeAll()
        refresh()
        if taps.isEmpty { setTapList() }
        for tap in old { AudioHardwareDestroyProcessTap(tap.id) }
    }

    private func setTapList() {
        var list = ([anchor].compactMap { $0 } + Array(taps.values)).map(\.uid) as CFArray
        var address = Self.address(kAudioAggregateDevicePropertyTapList)
        let status = withUnsafeMutablePointer(to: &list) {
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<CFArray>.size), $0)
        }
        if status != noErr { log.error("\(Self.error(status, "update the sound sources").localizedDescription, privacy: .public)") }
    }

    private func wantedKeys() -> Set<TapKey> {
        let processes = Self.audioProcesses()
        let ownPID = getpid()
        // AnyRemote's own sound (a viewer playing another Mac's sound) never
        // goes back out: on one Mac with two copies it would echo forever.
        let own = processes.filter { process in
            process.pid == ownPID || process.bundleID?.hasPrefix("com.localhost-copilot.anyremote") == true
                || process.responsiblePID == ownPID
        }
        switch scope {
        case .system:
            return [.system(excluding: own.map(\.object).sorted())]
        case .applications(let pids):
            let ownObjects = Set(own.map(\.object))
            return Set(processes.lazy
                .filter { !ownObjects.contains($0.object) && (pids.contains($0.pid) || pids.contains($0.responsiblePID)) }
                .map { .process($0.object) })
        }
    }

    private struct AudioProcess {
        var object: AudioObjectID
        var pid: pid_t
        var responsiblePID: pid_t
        var bundleID: String?
    }

    private static func audioProcesses() -> [AudioProcess] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.compactMap { object in
            var pid: pid_t = -1
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = Self.address(kAudioProcessPropertyPID)
            guard AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr, pid > 0
            else { return nil }
            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var bundleAddress = Self.address(kAudioProcessPropertyBundleID)
            let bundleID = AudioObjectGetPropertyData(object, &bundleAddress, 0, nil, &bundleSize, &bundle) == noErr
                ? bundle?.takeRetainedValue() as String? : nil
            return AudioProcess(object: object, pid: pid, responsiblePID: responsiblePID(for: pid), bundleID: bundleID)
        }
    }

    private static func makeTap(processes: [AudioObjectID], exclusive: Bool, mutes: Bool) throws -> Tap {
        let description = exclusive
            ? CATapDescription(stereoGlobalTapButExcludeProcesses: processes)
            : CATapDescription(stereoMixdownOfProcesses: processes)
        description.name = "AnyRemote"
        description.isPrivate = true
        description.muteBehavior = mutes ? .mutedWhenTapped : .unmuted
        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &id)
        guard status == noErr else { throw error(status, "tap a sound source") }
        return Tap(id: id, uid: description.uuid.uuidString)
    }

    /// Frames per I/O cycle; every frame waits for its cycle to complete.
    static let ioFrames = UInt32(ProcessInfo.processInfo.environment["ANYREMOTE_AUDIO_IO_FRAMES"] ?? "") ?? 240

    private static func setBufferFrameSize(_ device: AudioObjectID, _ frames: UInt32) {
        guard frames > 0 else { return }
        var value = frames
        var address = address(kAudioDevicePropertyBufferFrameSize)
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        var actual: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &actual)
        log.notice("sound capture buffer \(actual) frames (asked \(frames), status \(status))")
    }

    private static func nominalSampleRate(_ device: AudioObjectID) -> Double {
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = address(kAudioDevicePropertyNominalSampleRate)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr, rate > 0 else {
            return AudioWireFormat.sampleRate
        }
        return rate
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func error(_ status: OSStatus, _ action: String) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Could not \(action) (\(status))."])
    }
}

/// What the I/O thread uses: a mix buffer allocated up front, and the rate.
private final class RenderState: @unchecked Sendable {
    static let maximumFrames = 16_384
    private let mix = UnsafeMutablePointer<Float>.allocate(capacity: maximumFrames * 2)
    private let rate = OSAllocatedUnfairLock(initialState: AudioWireFormat.sampleRate)
    private var lastSampleTime: Double?

    var sampleRate: Double {
        get { rate.withLock { $0 } }
        set { rate.withLock { $0 = newValue } }
    }

    func release() { mix.deallocate() }

    /// Mixes every tap's stereo stream into one and hands it on. With no
    /// stream (nothing tapped), the elapsed time is handed on as silence, so
    /// the viewer keeps a steady stream.
    func process(_ input: UnsafePointer<AudioBufferList>, time: UnsafePointer<AudioTimeStamp>, handler: ProcessAudioTap.Handler) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let sampleTime = time.pointee.mFlags.contains(.sampleTimeValid) ? time.pointee.mSampleTime : nil
        var frames = 0
        for buffer in buffers where buffer.mNumberChannels > 0 {
            frames = max(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / Int(buffer.mNumberChannels))
        }
        if frames == 0, let sampleTime, let last = lastSampleTime, sampleTime > last {
            frames = Int(sampleTime - last)
        }
        if let sampleTime { lastSampleTime = sampleTime }
        frames = min(frames, Self.maximumFrames)
        guard frames > 0 else { return }
        mix.update(repeating: 0, count: frames * 2)
        for buffer in buffers {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = Int(buffer.mNumberChannels)
            let count = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / max(1, channels))
            switch channels {
            case 1:
                for index in 0..<count {
                    mix[index * 2] += data[index]
                    mix[index * 2 + 1] += data[index]
                }
            case 2...:
                for index in 0..<count {
                    mix[index * 2] += data[index * channels]
                    mix[index * 2 + 1] += data[index * channels + 1]
                }
            default:
                break
            }
        }
        let hostNanos = time.pointee.mFlags.contains(.hostTimeValid)
            ? HostClock.nanos(fromMachTime: time.pointee.mHostTime) : HostClock.nowNanos()
        handler(UnsafeBufferPointer(start: mix, count: frames * 2), sampleRate, hostNanos)
    }
}
