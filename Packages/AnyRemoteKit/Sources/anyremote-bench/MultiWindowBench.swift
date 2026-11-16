// Several windows streamed at once, as opening an app with all its windows
// does: does each extra window cost anything while it stands still, and does
// the one in use get slower?
//
//   anyremote-bench --windows N [--busy K] [--synthetic WxH] [--seconds S]
//                   [--app <name>] [--connect <host>:<port> --code <code>]
//
// Opens N synthetic windows here, the first K scrolling every display frame
// and the others still, streams them all through the host agent (in this
// process, or the one at `--connect`) and the viewer client, and prints per
// stream what the viewer received and what the host reported, after a
// warm-up. `--app` streams that app's windows too, after these: windows of
// another process, where this process's scrolling doesn't reach. With `--connect` to a `--host` running in another process, the
// host's processor time can be read from that process alone.

import AnyRemoteClient
import AnyRemoteHost
import AnyRemoteMedia
import AnyRemoteWire
import CoreGraphics
import Foundation
import Network

func runMultiWindowBench(_ options: Options, windowIDs ownWindowIDs: [CGWindowID], busy: Int) async throws {
    var service: HostService?
    let endpoint: NWEndpoint
    let code: PairingCode
    if let target = options.connect {
        let parts = target.split(separator: ":")
        guard parts.count >= 2, let port = UInt16(parts.last!), let parsed = PairingCode(options.code ?? "") else {
            print("--connect expects host:port and --code")
            exit(2)
        }
        endpoint = .hostPort(host: .init(parts.dropLast().joined(separator: ":")), port: .init(rawValue: port)!)
        code = parsed
    } else {
        setenv("ANYREMOTE_HOME", NSTemporaryDirectory() + "anyremote-bench", 1)
        let store = HostSettingsStore()
        let host = HostService(settings: store, options: .init(port: 0, advertise: false))
        for id in ownWindowIDs { host.allowOwnWindow(id) }
        try host.start()
        service = host
        while host.port == nil || host.port == 0 { try await Task.sleep(for: .milliseconds(20)) }
        code = store.settings.code!
        endpoint = .hostPort(host: "127.0.0.1", port: .init(rawValue: host.port!)!)
    }

    let client = RemoteHostClient(endpoint: endpoint, code: code, viewerName: "anyremote-bench")
    let welcome = try await client.connect()
    print("connected to \(welcome.hostName) (missing permissions: \(welcome.missingPermissions))")

    var windowIDs = ownWindowIDs
    var labels = ownWindowIDs.indices.map { $0 < busy ? "scroll" : "still" }
    if let filter = options.appFilter {
        let others = try await client.listWindows(thumbnailMaxPixels: 0).windows.filter {
            $0.applicationName.localizedCaseInsensitiveContains(filter)
        }
        windowIDs += others.map(\.windowID)
        labels += others.map { _ in filter }
    }

    let reports = HostReports()
    let started = AsyncStream<StreamDescription>.makeStream()
    client.onEvent = { event in
        switch event {
        case .streamStarted(let description) where description.role == .window:
            started.continuation.yield(description)
        case .streamEnded(let streamID, let reason):
            print("stream \(streamID) ended: \(reason)")
        case .hostReport(let streamID, let report):
            reports.add(report, for: streamID)
        case .disconnected(let reason):
            print("disconnected: \(reason ?? "")")
            exit(1)
        default: break
        }
    }

    // Open them all at once, as the host does for an app's windows.
    for id in windowIDs { client.openWindow(id) }
    var streamOf: [CGWindowID: UInt16] = [:]
    var statsOf: [UInt16: PipelineStats] = [:]
    var iterator = started.stream.makeAsyncIterator()
    while streamOf.count < windowIDs.count, let description = await iterator.next() {
        let stats = PipelineStats()
        streamOf[description.windowID] = description.streamID
        statsOf[description.streamID] = stats
        client.attach(streamID: description.streamID, stats: stats) { _ in }
    }

    // Warm-up: first keyframes, encoder ramp-up.
    try await Task.sleep(for: .seconds(2))
    for stats in statsOf.values { _ = stats.drain() }
    reports.reset()
    let cpuStart = processorSeconds()
    let wallStart = Date()
    var summaries: [UInt16: [PipelineStats.Summary]] = [:]
    let deadline = Date().addingTimeInterval(options.seconds)
    while Date() < deadline {
        try await Task.sleep(for: .seconds(1))
        for (streamID, stats) in statsOf { summaries[streamID, default: []].append(stats.drain()) }
    }
    let cpu = (processorSeconds() - cpuStart) / Date().timeIntervalSince(wallStart) * 100

    print(String(format: "\n%d windows (%d of ours scrolling), %.0f s", windowIDs.count, busy, options.seconds))
    print("window   state     fps  Mbps  receive p50/p95  encode p50/p95  wait p50  (host fps)")
    var totalMegabits = 0.0
    for (index, id) in windowIDs.enumerated() {
        guard let streamID = streamOf[id], let samples = summaries[streamID] else { continue }
        let fps = samples.map { $0.framesPerSecond }.reduce(0, +) / Double(samples.count)
        let megabits = samples.map { $0.megabitsPerSecond }.reduce(0, +) / Double(samples.count)
        totalMegabits += megabits
        // Seconds without frames have no latency; leave them out.
        let moving = samples.filter { $0.p50[.receive] != nil }
        func mean(_ values: [Double]) -> Double { values.isEmpty ? .nan : values.reduce(0, +) / Double(values.count) }
        let receive50 = mean(moving.compactMap { $0.p50[.receive] })
        let receive95 = mean(moving.compactMap { $0.p95[.receive] })
        let nan = Double.nan
        let host = reports.mean(for: streamID)
        print(String(format: "%-8d %-8@ %4.1f %5.1f   %6.2f / %6.2f   %5.2f / %5.2f   %5.2f    (%4.1f)",
                     index + 1, labels[index] as NSString, fps, megabits,
                     receive50, receive95, host?.encodeP50 ?? nan, host?.encodeP95 ?? nan,
                     host?.waitP50 ?? nan, host?.framesPerSecond ?? nan))
    }
    print(String(format: "total %.1f Mbps; this process %.0f%% CPU (%@)", totalMegabits, cpu,
                 (service == nil ? "viewer and windows" : "host, viewer and windows") as NSString))

    client.onEvent = nil
    for streamID in statsOf.keys { client.detach(streamID: streamID) }
    client.disconnect()
    try await Task.sleep(for: .milliseconds(300))
    service?.stop()
}

/// User and system processor time of this process so far.
private func processorSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

/// The host's per-stream reports, averaged over the measurement.
private final class HostReports: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [UInt16: [HostStreamReport]] = [:]

    func add(_ report: HostStreamReport, for streamID: UInt16) {
        lock.withLock { reports[streamID, default: []].append(report) }
    }

    func reset() { lock.withLock { reports.removeAll() } }

    /// Reports of seconds that had frames; nil if none had.
    func mean(for streamID: UInt16) -> (encodeP50: Double, encodeP95: Double, waitP50: Double,
                                         framesPerSecond: Double)? {
        let all = lock.withLock { reports[streamID] ?? [] }
        let moving = all.filter { $0.framesPerSecond > 0 }
        guard !moving.isEmpty else { return all.isEmpty ? nil : (.nan, .nan, .nan, 0) }
        let count = Double(moving.count)
        return (moving.map(\.encodeP50).reduce(0, +) / count, moving.map(\.encodeP95).reduce(0, +) / count,
                moving.map(\.waitP50).reduce(0, +) / count,
                all.map(\.framesPerSecond).reduce(0, +) / Double(all.count))
    }
}
