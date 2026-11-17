// Headless benchmark and network tool.
//
// In-process pipeline (no network):
//   anyremote-bench [--app <name> | --synthetic WxH] [--seconds N] [--bitrate Mbps] [--loss 0..1]
// Through the real host agent and viewer client over 127.0.0.1 (TCP + sealed UDP):
//   anyremote-bench --network [--app <name> | --synthetic WxH] [--seconds N]
// Run only a host agent (prints its pairing code):
//   anyremote-bench --host [--port N] [--synthetic WxH]
// Headless viewer against a running host:
//   anyremote-bench --connect <host>:<port> --code <pairing code> [--app <name>] [--seconds N]
//
// The viewer's microphone into this Mac's AnyRemote Microphone, over
// 127.0.0.1 (needs the driver; see MicrophoneBench.swift):
//   anyremote-bench --microphone [--seconds N]
//
// Full frame vs strips (see TileBench.swift):
//   anyremote-bench --tiles [--seconds N] [--strips 4]
//
// Drag and drop through the host agent (see DragBench.swift):
//   anyremote-bench --drag-test <scenario> --file <path> [--from x,y] [--to x,y]
//
// Several windows at once, some still (see MultiWindowBench.swift):
//   anyremote-bench --windows N [--busy K] [--synthetic WxH] [--seconds N] [--connect … --code …]
//
// The frame rate virtual displays deliver at each refresh rate (see RefreshBench.swift):
//   anyremote-bench --refresh-test 60,120,144 [--synthetic WxH] [--seconds N]
//
// `--synthetic` opens a window of W×H points that scrolls dense text every
// display frame: a reproducible worst-case workload for latency comparisons.

import AnyRemoteClient
import AnyRemoteDiagnostics
import AnyRemoteHost
import AnyRemoteMedia
import AnyRemoteWire
import AppKit
import Network
@preconcurrency import ScreenCaptureKit

struct Options: Sendable {
    var appFilter: String?
    var synthetic: CGSize?
    var seconds = 5.0
    var bitrate = 40
    var loss = 0.0
    var pacing = 120
    var realTime = false
    var network = false
    var hostOnly = false
    var port: UInt16 = 0
    var connect: String?
    var code: String?
    var tiles = false
    var strips = 4
    var microphone = false
    var dragScenario: String?
    var dragFile: String?
    var dragFrom = CGPoint(x: 300, y: 300)
    var dragTo = CGPoint(x: 850, y: 300)
    var windows = 0
    var busy = 1
    var refreshRates: [Int] = []
}

func parsePoint(_ text: String?) -> CGPoint? {
    let parts = (text ?? "").split(separator: ",").compactMap { Double($0) }
    return parts.count == 2 ? CGPoint(x: parts[0], y: parts[1]) : nil
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = CommandLine.arguments.dropFirst().makeIterator()
    while let argument = arguments.next() {
        switch argument {
        case "--app": options.appFilter = arguments.next()
        case "--synthetic":
            let parts = (arguments.next() ?? "").split(separator: "x").compactMap { Double($0) }
            guard parts.count == 2 else { print("--synthetic expects WxH"); exit(2) }
            options.synthetic = CGSize(width: parts[0], height: parts[1])
        case "--seconds": options.seconds = Double(arguments.next() ?? "") ?? options.seconds
        case "--bitrate": options.bitrate = Int(arguments.next() ?? "") ?? options.bitrate
        case "--loss": options.loss = Double(arguments.next() ?? "") ?? options.loss
        case "--pacing": options.pacing = Int(arguments.next() ?? "") ?? options.pacing
        case "--realtime": options.realTime = true
        case "--network": options.network = true
        case "--host": options.hostOnly = true
        case "--port": options.port = UInt16(arguments.next() ?? "") ?? 0
        case "--connect": options.connect = arguments.next()
        case "--code": options.code = arguments.next()
        case "--tiles": options.tiles = true
        case "--windows": options.windows = Int(arguments.next() ?? "") ?? 0
        case "--busy": options.busy = Int(arguments.next() ?? "") ?? options.busy
        case "--microphone": options.microphone = true
        case "--refresh-test": options.refreshRates = (arguments.next() ?? "").split(separator: ",").compactMap { Int($0) }
        case "--strips": options.strips = Int(arguments.next() ?? "") ?? options.strips
        case "--drag-test": options.dragScenario = arguments.next()
        case "--file": options.dragFile = arguments.next()
        case "--from": options.dragFrom = parsePoint(arguments.next()) ?? options.dragFrom
        case "--to": options.dragTo = parsePoint(arguments.next()) ?? options.dragTo
        default:
            print("unknown argument \(argument)")
            exit(2)
        }
    }
    return options
}

func runBenchmark(_ options: Options, syntheticWindowID: CGWindowID?) async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    let window: SCWindow?
    if let syntheticWindowID {
        window = content.windows.first { $0.windowID == syntheticWindowID }
    } else {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        window = content.windows.first { window in
            window.windowLayer == 0 && window.frame.width >= 200 && window.frame.height >= 150
                && window.owningApplication?.processID != ownPID
                && (options.appFilter.map {
                    window.owningApplication?.applicationName.localizedCaseInsensitiveContains($0) ?? false
                } ?? true)
        }
    }
    guard let window else {
        print("no matching on-screen window")
        exit(1)
    }
    print("window: \(window.owningApplication?.applicationName ?? "?") — \(window.title ?? "") \(window.frame)")

    let stats = PipelineStats()
    let lossRate = options.loss
    let firstFrame = OnceFlag()
    let senderBox = SenderBox()
    let receiver = WindowStreamReceiver(
        streamID: 1,
        stats: stats,
        onFrame: { frame in
            guard firstFrame.claim() else { return }
            let type = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
            let fourCC = String((0..<4).map { Character(UnicodeScalar(UInt8((type >> (24 - $0 * 8)) & 0xff))) })
            print("first decoded frame: \(frame.pixelWidth)x\(frame.pixelHeight) \(fourCC) scale=\(frame.scale)")
        },
        onKeyframeRequest: { senderBox.sender?.requestKeyframe() }
    )
    receiver.remoteClock = .local()
    receiver.recordsFrames = false

    let sender = WindowStreamSender(
        window: window,
        streamID: 1,
        configuration: .init(averageBitRate: options.bitrate * 1_000_000,
                             encoderPacingFrameRate: options.pacing, realTime: options.realTime),
        stats: stats,
        send: { datagrams in
            receiver.receive(lossRate > 0 ? datagrams.filter { _ in Double.random(in: 0..<1) >= lossRate } : datagrams)
        }
    )
    senderBox.sender = sender

    try await sender.start()
    let deadline = Date().addingTimeInterval(options.seconds)
    while Date() < deadline {
        try await Task.sleep(for: .seconds(1))
        print(stats.drain())
    }
    await sender.stop()
    receiver.close()
    print("stages (ms p50/p95): capture=SCK pts→handler, wait=encoder busy, encode, decode, receive=capture→reassembled")
}

/// Host agent + viewer client over loopback, or a viewer against `--connect`.
func runNetwork(_ options: Options, syntheticWindowID: CGWindowID?) async throws {
    var service: HostService?
    let endpoint: NWEndpoint
    let credential: PairingCredential
    if let target = options.connect {
        let parts = target.split(separator: ":")
        guard parts.count >= 2, let port = UInt16(parts.last!), let parsed = PairingCode(options.code ?? "") else {
            print("--connect expects host:port and --code")
            exit(2)
        }
        endpoint = .hostPort(host: .init(parts.dropLast().joined(separator: ":")), port: .init(rawValue: port)!)
        credential = .legacy(parsed)
    } else {
        setenv("ANYREMOTE_HOME", NSTemporaryDirectory() + "anyremote-bench", 1)
        let store = HostSettingsStore()
        let host = HostService(settings: store, options: .init(port: options.port, advertise: options.hostOnly))
        if let syntheticWindowID { host.allowOwnWindow(syntheticWindowID) }
        try host.start()
        service = host
        while host.port == nil || host.port == 0 { try await Task.sleep(for: .milliseconds(20)) }
        credential = store.loopbackCredential
        endpoint = .hostPort(host: "127.0.0.1", port: .init(rawValue: host.port!)!)
        if options.hostOnly {
            // Codes stay out of the output: the Dev viewer reads the
            // legacy code from host.json, a pairing code from pairing-code.
            print("host listening on port \(host.port!)")
            host.onPairingRequest = { prompt in
                FileManager.default.createFile(atPath: NSTemporaryDirectory() + "anyremote-bench/pairing-code",
                                               contents: Data(prompt.code.utf8), attributes: [.posixPermissions: 0o600])
                print("pairing request from \(prompt.viewerName); its code is in pairing-code")
            }
            host.onPairingEnded = { _, paired in
                try? FileManager.default.removeItem(atPath: NSTemporaryDirectory() + "anyremote-bench/pairing-code")
                print(paired ? "paired" : "pairing ended without pairing")
            }
            let permissions = HostService.permissions
            print("permissions: screen=\(permissions.screenRecording) ax=\(permissions.accessibility) post=\(permissions.postEvents)")
            // How often the synthetic window redraws: its display's refresh rate.
            var redraws = await MainActor.run { SyntheticWorkloadWindow.redraws }
            while true {
                try await Task.sleep(for: .seconds(syntheticWindowID == nil ? 3600 : 2))
                let now = await MainActor.run { SyntheticWorkloadWindow.redraws }
                if syntheticWindowID != nil {
                    let screens = CGDisplayCopyDisplayMode(CGMainDisplayID()).map { "\($0.refreshRate)" } ?? "?"
                    print("synthetic window redraws \((now - redraws) / 2)/s (main display \(screens) Hz)")
                }
                redraws = now
            }
        }
    }

    let client = RemoteHostClient(endpoint: endpoint, credential: credential, viewerName: "anyremote-bench")
    let welcome = try await client.connect()
    print("connected to \(welcome.hostName) (missing permissions: \(welcome.missingPermissions))")
    let listing = try await client.listWindows()
    let candidates = listing.windows.filter { window in
        if let syntheticWindowID { return window.windowID == syntheticWindowID }
        return window.frame.width >= 200 && window.frame.height >= 150
            && (options.appFilter.map { window.applicationName.localizedCaseInsensitiveContains($0) } ?? true)
    }
    guard let target = candidates.first else {
        print("no matching window among \(listing.windows.count)")
        exit(1)
    }
    print("window: \(target.applicationName) — \(target.title) \(target.frame)")

    let stats = PipelineStats()
    let started = AsyncStream<StreamDescription>.makeStream()
    client.onEvent = { event in
        switch event {
        case .streamStarted(let description):
            if description.role == .window {
                started.continuation.yield(description)
            } else {
                print("child stream \(description.streamID): window \(description.windowID) layer \(description.layer) \(description.frame) '\(description.title)' \(description.applicationName)")
            }
        case .streamEnded(let streamID, let reason):
            print("stream \(streamID) ended: \(reason)")
        case .hostReport(_, let report):
            print(String(format: "  host: lead %.2f wait %.2f encode %.2f/%.2f %.1ffps %.1fMbps (target %d)",
                         report.captureP50, report.waitP50, report.encodeP50, report.encodeP95,
                         report.framesPerSecond, report.megabitsPerSecond, report.bitRate / 1_000_000))
        case .disconnected(let reason):
            print("disconnected: \(reason ?? "")")
            exit(1)
        default: break
        }
    }
    client.openWindow(target.windowID)
    var iterator = started.stream.makeAsyncIterator()
    guard let description = await iterator.next() else { exit(1) }
    let firstFrame = OnceFlag()
    client.attach(streamID: description.streamID, stats: stats) { frame in
        guard firstFrame.claim() else { return }
        print("first decoded frame: \(frame.pixelWidth)x\(frame.pixelHeight) scale=\(frame.scale)")
    }
    let deadline = Date().addingTimeInterval(options.seconds)
    while Date() < deadline {
        try await Task.sleep(for: .seconds(1))
        print("viewer: \(stats.drain())  rtt \(String(format: "%.2f", client.roundTripMilliseconds ?? -1))ms")
    }
    client.onEvent = nil
    client.detach(streamID: description.streamID)
    client.disconnect()
    try await Task.sleep(for: .milliseconds(200))
    service?.stop()
    print("receive = host capture → reassembled on viewer (clock-synced), includes encode and network")
}

final class SenderBox: @unchecked Sendable {
    var sender: WindowStreamSender?
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
let options = parseOptions()
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
nonisolated(unsafe) var syntheticWindow: NSWindow?
nonisolated(unsafe) var benchWindows: [NSWindow] = []
if options.windows > 0 {
    let size = options.synthetic ?? CGSize(width: 1200, height: 800)
    benchWindows = MainActor.assumeIsolated {
        (0..<options.windows).map { index in
            SyntheticWorkloadWindow.open(size: size, origin: CGPoint(x: 40 + index * 50, y: 40 + index * 30),
                                         scrolls: index < options.busy)
        }
    }
} else if let size = options.synthetic, options.refreshRates.isEmpty {
    syntheticWindow = MainActor.assumeIsolated { SyntheticWorkloadWindow.open(size: size) }
}
let syntheticWindowID = syntheticWindow.map { CGWindowID($0.windowNumber) }
let benchWindowIDs = benchWindows.map { CGWindowID($0.windowNumber) }
Task.detached {
    // Let the synthetic window reach the window server before enumerating.
    if syntheticWindowID != nil || !benchWindowIDs.isEmpty { try? await Task.sleep(for: .milliseconds(500)) }
    do {
        if !options.refreshRates.isEmpty {
            try await runRefreshBench(rates: options.refreshRates, size: options.synthetic ?? CGSize(width: 1200, height: 800),
                                      seconds: options.seconds, bitRate: options.bitrate * 1_000_000)
        } else if let scenario = options.dragScenario {
            try await runDragBench(scenario: scenario, file: options.dragFile, from: options.dragFrom, to: options.dragTo)
        } else if options.microphone {
            try await runMicrophoneBench(seconds: options.seconds)
        } else if !benchWindowIDs.isEmpty {
            try await runMultiWindowBench(options, windowIDs: benchWindowIDs, busy: min(options.busy, benchWindowIDs.count))
        } else if options.tiles {
            try await runTileBench(seconds: options.seconds, strips: options.strips, realTime: options.realTime)
        } else if options.network || options.hostOnly || options.connect != nil {
            try await runNetwork(options, syntheticWindowID: syntheticWindowID)
        } else {
            try await runBenchmark(options, syntheticWindowID: syntheticWindowID)
        }
        exit(0)
    } catch {
        print("benchmark failed: \(error)")
        exit(1)
    }
}
application.run()
