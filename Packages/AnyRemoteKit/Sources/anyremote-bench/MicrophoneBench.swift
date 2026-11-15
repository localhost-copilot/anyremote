// Measures the microphone path in loopback: a viewer client sends a test
// tone (a click at every whole second of the host clock) through a host
// agent into the AnyRemote Microphone, and this process records from that
// microphone like any app would. Host and viewer share one clock here, so a
// click's arrival time minus its whole second is the delay from "captured"
// on the viewer to "recorded" by an app on the host: encode, network, jitter
// buffer, the feed's I/O buffer and the microphone's.
//
// While it runs, the AnyRemote Microphone is this Mac's default input (the
// host restores the previous one when the viewer leaves).

import AnyRemoteClient
import AnyRemoteHost
import AnyRemoteMedia
import CoreAudio
import Foundation
import Network

func runMicrophoneBench(seconds: Double) async throws {
    setenv("ANYREMOTE_MICROPHONE_TONE", "1", 1)
    guard MicrophoneCapture.testTone else {
        print("set ANYREMOTE_MICROPHONE_TONE=1 in the environment before launching")
        exit(2)
    }
    guard HostService.microphoneInstalled,
          let microphone = AudioDevices.device(uid: "com.localhost-copilot.anyremote.microphone") else {
        print("the AnyRemote Microphone driver is not installed")
        exit(1)
    }
    setenv("ANYREMOTE_HOME", NSTemporaryDirectory() + "anyremote-bench", 1)
    let store = HostSettingsStore()
    let host = HostService(settings: store, options: .init(port: 0, advertise: false))
    try host.start()
    while host.port == nil || host.port == 0 { try await Task.sleep(for: .milliseconds(20)) }
    let client = RemoteHostClient(endpoint: .hostPort(host: "127.0.0.1", port: .init(rawValue: host.port!)!),
                                  code: store.settings.code!, viewerName: "anyremote-bench")
    client.onEvent = { event in
        if case .microphone(let state) = event { print("viewer microphone: \(state)") }
    }
    client.setMicrophone(enabled: true)
    _ = try await client.connect()
    try await Task.sleep(for: .milliseconds(300))

    let recorder = ClickRecorder(device: microphone)
    try recorder.start()
    print("recording from the AnyRemote Microphone for \(Int(seconds)) s")
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        try await Task.sleep(for: .seconds(1))
        let delays = recorder.takeDelays()
        print("click delays (ms): \(delays.map { String(format: "%.1f", $0) }.joined(separator: " "))"
              + "  peak \(String(format: "%.2f", recorder.takePeak()))")
    }
    recorder.stop()
    client.disconnect()
    try await Task.sleep(for: .milliseconds(500))
    host.stop()
}

/// Records a device and reports when clicks (samples above 0.5 after a
/// quiet stretch) arrive, as milliseconds past the whole second.
final class ClickRecorder: @unchecked Sendable {
    private let device: AudioObjectID
    private var ioProc: AudioDeviceIOProcID?
    private let lock = NSLock()
    private var delays: [Double] = []
    private var peak: Float = 0
    private var quietFrames = 0

    init(device: AudioObjectID) {
        self.device = device
    }

    func start() throws {
        var ioProc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProc, device, nil) { [weak self] _, input, inputTime, _, _ in
            self?.process(input, inputTime)
        }
        guard status == noErr, let ioProc else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        self.ioProc = ioProc
        AudioDeviceStart(device, ioProc)
    }

    func stop() {
        guard let ioProc else { return }
        AudioDeviceStop(device, ioProc)
        AudioDeviceDestroyIOProcID(device, ioProc)
        self.ioProc = nil
    }

    func takeDelays() -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        let current = delays
        delays.removeAll()
        return current
    }

    func takePeak() -> Float {
        lock.lock()
        defer { lock.unlock() }
        let current = peak
        peak = 0
        return current
    }

    private func process(_ input: UnsafePointer<AudioBufferList>, _ time: UnsafePointer<AudioTimeStamp>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let buffer = buffers.first, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
        let channels = Int(max(1, buffer.mNumberChannels))
        let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
        let startNanos = HostClock.nanos(fromMachTime: time.pointee.mHostTime)
        lock.lock()
        defer { lock.unlock() }
        for frame in 0..<frames {
            let sample = abs(data[frame * channels])
            peak = max(peak, sample)
            if sample > 0.5 {
                // 0.5 s of tone since the last click: this is a new one.
                if quietFrames > 24_000 {
                    let nanos = startNanos + UInt64(Double(frame) / 48_000 * 1e9)
                    var past = Double(nanos % 1_000_000_000) / 1e6
                    if past > 500 { past -= 1000 }
                    delays.append(past)
                }
                quietFrames = 0
            } else {
                quietFrames += 1
            }
        }
    }
}
