import AnyRemoteMedia
import AnyRemoteNetwork
import AnyRemoteWire
import CoreAudio
import Foundation
import os

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Microphone")

/// Lets apps on this Mac record from a viewer's microphone.
///
/// The AnyRemote Microphone driver (`MicrophoneDriver/`) gives this Mac an
/// input device, and a hidden feed device whose sound that input returns.
/// While a viewer offers its microphone, the AnyRemote Microphone becomes
/// this Mac's default input, so apps record from it without being told. Once
/// an app actually records (the device runs somewhere), the viewer that sent
/// input last is asked to open its microphone; its packets play into the
/// feed. When the recording stops, so does the viewer's microphone.
///
/// Queue-confined to the host service's queue, except `receive(_:from:)`.
final class HostMicrophone: @unchecked Sendable {
    static let microphoneUID = "com.localhost-copilot.anyremote.microphone"
    static let feedUID = "com.localhost-copilot.anyremote.microphone.feed"
    /// Holds the input that was the default before ours, to restore it even
    /// after a crash.
    private static let previousInputFile = "microphone-previous-input"

    static var isInstalled: Bool { AudioDevices.device(uid: microphoneUID) != nil }

    /// This process made ours the default input for its viewers, and hasn't
    /// given it back yet.
    private static let activeLock = NSLock()
    nonisolated(unsafe) private static var activeHere = false
    static var isActiveHere: Bool {
        get { activeLock.withLock { activeHere } }
        set { activeLock.withLock { activeHere = newValue } }
    }

    private let queue: DispatchQueue

    // Queue-confined.
    private var offers: [UInt32: Offer] = [:]
    private var microphone = AudioObjectID(kAudioObjectUnknown)
    private var runningListener: AudioObjectPropertyListenerBlock?
    private var recording = false
    /// The session asked for its microphone, while an app records.
    private var sourceID: UInt32?
    private var reportTimer: DispatchSourceTimer?

    private struct Offer {
        weak var session: HostSession?
    }

    /// The source's packets → the feed, behind a lock for the socket queue.
    private let receiverLock = NSLock()
    private var receiver: (sessionID: UInt32, receiver: AudioStreamReceiver)?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    // MARK: Viewers

    /// A viewer offers its microphone, or withdraws it.
    func setOffered(_ offered: Bool, by session: HostSession) {
        dispatchPrecondition(condition: .onQueue(queue))
        if offered {
            offers[session.sessionID] = Offer(session: session)
        } else {
            offers.removeValue(forKey: session.sessionID)
            if sourceID == session.sessionID { sourceEnded() }
        }
        update()
    }

    func sessionEnded(_ session: HostSession) {
        guard offers[session.sessionID] != nil else { return }
        setOffered(false, by: session)
    }

    /// The driver was installed or removed.
    func driverChanged() {
        dispatchPrecondition(condition: .onQueue(queue))
        // Removed while in use: start over, without it.
        if microphone != kAudioObjectUnknown, !Self.isInstalled { deactivate() }
        update()
    }

    /// The source's microphone packets follow in `format`, or stop.
    func streamChanged(_ format: AudioStreamFormat?, from session: HostSession) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard session.sessionID == sourceID else { return }
        guard let format, recording else {
            replaceReceiver(with: nil)
            return
        }
        do {
            let receiver = try AudioStreamReceiver(format: format, destination: .device(uid: Self.feedUID))
            replaceReceiver(with: (session.sessionID, receiver))
            log.notice("recording from \(session.viewerName, privacy: .public)'s microphone")
        } catch {
            log.error("microphone feed unavailable: \(String(describing: error), privacy: .public)")
            replaceReceiver(with: nil)
        }
    }

    /// Thread-safe (the service's socket queue). `datagram` is an opened
    /// microphone `AudioPacket`.
    func receive(_ datagram: Data, from sessionID: UInt32) {
        receiverLock.lock()
        let current = receiver
        receiverLock.unlock()
        guard let current, current.sessionID == sessionID else { return }
        current.receiver.receive(datagram)
    }

    // MARK: State

    /// Brings the device, the default input and the request in line with the
    /// offers.
    private func update() {
        offers = offers.filter { $0.value.session != nil }
        let wanted = !offers.isEmpty
        if wanted, microphone == kAudioObjectUnknown {
            activate()
        } else if !wanted, microphone != kAudioObjectUnknown {
            deactivate()
        }
        if recording, sourceID == nil { askSource() }
    }

    private func activate() {
        guard let device = AudioDevices.device(uid: Self.microphoneUID) else {
            log.notice("a viewer offers its microphone, but the AnyRemote Microphone is not installed")
            return
        }
        microphone = device
        Self.isActiveHere = true
        Self.makeDefault(device)
        var address = AudioDevices.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.runningChanged() }
        AudioObjectAddPropertyListenerBlock(device, &address, queue, listener)
        runningListener = listener
        log.notice("AnyRemote Microphone is the default input")
        runningChanged()
    }

    private func deactivate() {
        if let runningListener {
            var address = AudioDevices.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectRemovePropertyListenerBlock(microphone, &address, queue, runningListener)
        }
        runningListener = nil
        microphone = AudioObjectID(kAudioObjectUnknown)
        recording = false
        sourceEnded()
        Self.restoreDefault(fallback: true)
        Self.isActiveHere = false
    }

    private func runningChanged() {
        guard microphone != kAudioObjectUnknown else { return }
        let running = AudioDevices.uint32(microphone, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0 != 0
        guard running != recording else { return }
        recording = running
        log.notice("an app \(running ? "started" : "stopped", privacy: .public) recording")
        if running {
            askSource()
        } else {
            sourceEnded()
        }
    }

    /// Asks the offering viewer that sent input last: the person at the
    /// controls is the one about to speak.
    private func askSource() {
        let candidates = offers.values.compactMap(\.session)
        guard let source = candidates.max(by: { $0.lastInputNanos < $1.lastInputNanos }) else { return }
        sourceID = source.sessionID
        source.connection.send(.microphoneWanted(true))
        startReports()
    }

    private func sourceEnded() {
        if let sourceID, let session = offers[sourceID]?.session {
            session.connection.send(.microphoneWanted(false))
        }
        sourceID = nil
        replaceReceiver(with: nil)
        reportTimer?.cancel()
        reportTimer = nil
    }

    private func replaceReceiver(with new: (sessionID: UInt32, receiver: AudioStreamReceiver)?) {
        receiverLock.lock()
        let previous = receiver
        receiver = new
        receiverLock.unlock()
        previous?.receiver.close()
    }

    /// Development: `/usr/bin/log show --info` shows the feed's statistics.
    private func startReports() {
        guard reportTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: .seconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.receiverLock.lock()
            let current = self.receiver
            self.receiverLock.unlock()
            if let report = current?.receiver.takeReport() {
                log.info("microphone \(report.description, privacy: .public)")
            }
        }
        timer.resume()
        reportTimer = timer
    }

    // MARK: Default input

    private static func makeDefault(_ device: AudioObjectID) {
        let current = AudioDevices.defaultInput
        if let current, current != device, let uid = AudioDevices.uid(of: current) {
            try? AnyRemoteStorage.writePrivate(Data(uid.utf8), to: previousInputFile)
        }
        if current != device, !AudioDevices.setDefaultInput(device) {
            log.error("could not make the AnyRemote Microphone the default input")
        }
    }

    /// Gives back the input that was the default before ours, if ours still
    /// is (the person may have picked another one meanwhile). With
    /// `fallback`, when that input is gone or wasn't noted, another one
    /// takes over, so ours never stays the default once no viewer offers a
    /// microphone: it was noted by a host that ended without restoring it
    /// (killed, or a development host with a storage of its own), and every
    /// host after that found ours the default already and had nothing to
    /// note. Without `fallback` (a host starting, while another may still be
    /// using ours), only a noted input is given back.
    static func restoreDefault(fallback: Bool = false) {
        let file = AnyRemoteStorage.directory.appendingPathComponent(previousInputFile)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let ours = AudioDevices.device(uid: microphoneUID), AudioDevices.defaultInput == ours else { return }
        let noted = AnyRemoteStorage.read(previousInputFile)
            .flatMap { AudioDevices.device(uid: String(decoding: $0, as: UTF8.self)) }
        guard let previous = noted ?? (fallback ? otherInput() : nil) else {
            if fallback { log.notice("no other input to make the default") }
            return
        }
        AudioDevices.setDefaultInput(previous)
        log.notice("restored the default input\(noted == nil ? " (another one; the earlier one is unknown or gone)" : "", privacy: .public)")
    }

    /// The input macOS would most likely pick itself: a built-in microphone,
    /// else the first other one there is.
    private static func otherInput() -> AudioObjectID? {
        let others = AudioDevices.inputDevices.filter {
            let uid = AudioDevices.uid(of: $0)
            return uid != microphoneUID && uid != feedUID
        }
        return others.first { AudioDevices.uint32($0, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn }
            ?? others.first
    }
}
