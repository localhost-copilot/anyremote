@preconcurrency import AVFoundation
import AnyRemoteMedia
import AnyRemoteWire
import Foundation
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Microphone")

/// The viewer's microphone, sent to the host while an app there records.
///
/// The host says when an app starts and stops recording from the AnyRemote
/// Microphone (`microphoneWanted`); only then is this Mac's microphone open,
/// so its recording indicator means what it says. A short stop is bridged:
/// apps that stop and start again at once (dictation between phrases) keep
/// the microphone rather than losing the first moment of sound to reopening.
final class ViewerMicrophone: @unchecked Sendable {
    typealias State = RemoteHostClient.MicrophoneState

    private static let linger: DispatchTimeInterval = .milliseconds(1500)

    private let queue: DispatchQueue
    private let sendDatagram: @Sendable (Data) -> Void
    private let sendControl: @Sendable (ControlMessage) -> Void
    private let onState: @Sendable (State) -> Void

    // Queue-confined.
    private var wanted = false
    private var capture: MicrophoneCapture?
    private var pendingStop: DispatchWorkItem?
    private var state = State.off

    /// `queue`: the client's queue, which every call comes from.
    init(queue: DispatchQueue, sendDatagram: @escaping @Sendable (Data) -> Void,
         sendControl: @escaping @Sendable (ControlMessage) -> Void, onState: @escaping @Sendable (State) -> Void) {
        self.queue = queue
        self.sendDatagram = sendDatagram
        self.sendControl = sendControl
        self.onState = onState
    }

    func setWanted(_ wanted: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        self.wanted = wanted
        if wanted {
            pendingStop?.cancel()
            pendingStop = nil
            guard capture == nil else { return }
            requestAccessThenStart()
        } else {
            guard capture != nil else {
                if state == .denied { setState(.off) }
                return
            }
            guard pendingStop == nil else { return }
            let stop = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingStop = nil
                if !self.wanted { self.close(notifyHost: true) }
            }
            pendingStop = stop
            queue.asyncAfter(deadline: .now() + Self.linger, execute: stop)
        }
    }

    /// The connection ended.
    func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        wanted = false
        pendingStop?.cancel()
        pendingStop = nil
        close(notifyHost: false)
    }

    private func requestAccessThenStart() {
        if MicrophoneCapture.testTone {
            open()
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            open()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard let self else { return }
                self.queue.async {
                    guard self.wanted, self.capture == nil else { return }
                    if granted { self.open() } else { self.setState(.denied) }
                }
            }
        default:
            log.notice("the other Mac wants the microphone, but it isn't allowed here")
            setState(.denied)
        }
    }

    private func open() {
        let sender: AudioStreamSender
        do {
            sender = try AudioStreamSender(kind: DatagramKind.microphone, send: sendDatagram)
        } catch {
            log.error("microphone encoder unavailable: \(String(describing: error), privacy: .public)")
            return
        }
        let capture = MicrophoneCapture { frames, rate, hostNanos in
            sender.submit(frames, sampleRate: rate, hostNanos: hostNanos)
        }
        do {
            try capture.start()
        } catch {
            log.error("microphone unavailable: \(error.localizedDescription, privacy: .public)")
            return
        }
        self.capture = capture
        sendControl(.microphoneStream(sender.format))
        setState(.on)
        log.notice("sending the microphone")
    }

    private func close(notifyHost: Bool) {
        guard let capture else {
            setState(.off)
            return
        }
        self.capture = nil
        capture.stop()
        if notifyHost { sendControl(.microphoneStream(nil)) }
        setState(.off)
        log.notice("stopped sending the microphone")
    }

    private func setState(_ new: State) {
        guard new != state else { return }
        state = new
        onState(new)
    }
}
