// What frame rate a virtual display of a given refresh rate delivers.
//
//   anyremote-bench --refresh-test 60,120,144 [--synthetic WxH] [--seconds N]
//
// For each rate: makes a virtual display at that rate (as remote windows
// get), moves a window scrolling text every display refresh onto it, and
// captures and encodes that window as the host does (capture cadence = the
// rate), decoding in-process. Reports the display's mode, how often the
// window redrew (the display's real refresh) and the frames that made it
// through capture, encode and decode, per second.
//
// Creating a display rearranges this Mac's displays for a moment: don't run
// it while someone uses this Mac remotely.

import AnyRemoteDiagnostics
import AnyRemoteHost
import AnyRemoteMedia
import AppKit
@preconcurrency import ScreenCaptureKit

func runRefreshBench(rates: [Int], size: CGSize, seconds: Double, bitRate: Int) async throws {
    let window = await MainActor.run { SyntheticWorkloadWindow.open(size: size) }
    let windowID = await MainActor.run { CGWindowID(window.windowNumber) }
    var results: [String] = []
    for rate in rates {
        guard let display = VirtualDisplay(pointSize: CGSize(width: size.width + 200, height: size.height + 200),
                                           refreshRate: Double(rate), name: "AnyRemote Test", productID: 0xFFF0)
        else {
            print("\(rate) Hz: no display")
            continue
        }
        display.makeExtended()
        display.useHiDPIMode()
        display.placeAtCorner()
        try await Task.sleep(for: .milliseconds(500))
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let modeText = mode.map { "\($0.width)x\($0.height)pt \($0.pixelWidth)x\($0.pixelHeight)px \($0.refreshRate) Hz" } ?? "?"
        print("\(rate) Hz requested: display \(display.displayID) mode \(modeText)")
        // Top-left global points → AppKit's bottom-left screen coordinates.
        let bounds = display.bounds
        await MainActor.run {
            let mainHeight = NSScreen.screens.first?.frame.height ?? 0
            window.setFrameTopLeftPoint(NSPoint(x: bounds.minX + 20, y: mainHeight - bounds.minY - 20))
            window.orderFrontRegardless()
        }
        try await Task.sleep(for: .milliseconds(700))

        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
            print("window not found")
            continue
        }
        let stats = PipelineStats()
        let receiver = WindowStreamReceiver(streamID: 1, stats: stats, onFrame: { _ in }, onKeyframeRequest: {})
        receiver.remoteClock = .local()
        receiver.recordsFrames = false
        let sender = WindowStreamSender(window: scWindow, streamID: 1,
                                        configuration: .init(averageBitRate: bitRate, expectedFrameRate: rate),
                                        stats: stats) { receiver.receive($0) }
        try await sender.start()
        try await Task.sleep(for: .seconds(1))
        _ = stats.drain()
        let redrawsBefore = await MainActor.run { SyntheticWorkloadWindow.redraws }
        let started = Date()
        var fps: [Double] = []
        while Date().timeIntervalSince(started) < seconds {
            try await Task.sleep(for: .seconds(1))
            let summary = stats.drain()
            fps.append(summary.framesPerSecond)
            print("  \(summary)")
        }
        let redraws = await MainActor.run { SyntheticWorkloadWindow.redraws } - redrawsBefore
        let redrawRate = Double(redraws) / Date().timeIntervalSince(started)
        await sender.stop()
        receiver.close()
        let sorted = fps.sorted()
        let line = String(format: "%3d Hz: mode %.0f Hz, window redraws %.1f/s, decoded fps median %.1f (min %.1f)",
                          rate, mode?.refreshRate ?? 0, redrawRate, sorted[sorted.count / 2], sorted.first ?? 0)
        print(line)
        results.append(line)
        // Back onto this Mac's screen before the display goes.
        await MainActor.run { window.setFrameOrigin(NSPoint(x: 40, y: 40)) }
        try await Task.sleep(for: .milliseconds(300))
        withExtendedLifetime(display) {}
        try await Task.sleep(for: .milliseconds(800))
    }
    print("\n" + results.joined(separator: "\n"))
}
