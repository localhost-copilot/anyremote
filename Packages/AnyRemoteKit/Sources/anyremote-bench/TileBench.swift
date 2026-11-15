// Full frame vs horizontal strips (Apple Screen Sharing's four tiles).
//
//   anyremote-bench --tiles [--seconds N] [--strips 4]
//
// Captures the main display at its native pixels twice in turn: as one
// stream with one encoder and decoder, and as N horizontal strips, each its
// own ScreenCaptureKit stream (sourceRect) with its own encoder and decoder.
// A strip whose content didn't change produces no frame, so only changed
// strips are encoded. For each host display frame it reports how long from
// ScreenCaptureKit handing the frame over until every changed part is
// decoded (the network, ~1 ms on a LAN, is left out), and how many strips
// changed. Workloads, each in its own window: a small field updated like
// typing, a 900×600 window scrolling text, and the same text scrolling
// across the whole display.

import AnyRemoteDiagnostics
import AnyRemoteMedia
import AnyRemoteWire
import AppKit
@preconcurrency import ScreenCaptureKit

/// One captured region with its own encoder and decoder.
final class RegionPipeline: NSObject, SCStreamOutput, @unchecked Sendable {
    let index: Int
    private let queue: DispatchQueue
    private var stream: SCStream?
    private let encoder: HEVCEncoder
    private let decoder: HEVCDecoder
    private let pixelSize: (width: Int, height: Int)
    private let scale: CGFloat

    init(index: Int, display: SCDisplay, sourceRect: CGRect, scale: CGFloat, bitRate: Int, realTime: Bool,
         onDecoded: @escaping @Sendable (_ index: Int, _ frame: DecodedFrame) -> Void) {
        self.index = index
        self.scale = scale
        queue = DispatchQueue(label: "bench.region.\(index)", qos: .userInteractive)
        pixelSize = (Int((sourceRect.width * scale).rounded()), Int((sourceRect.height * scale).rounded()))
        let decoder = HEVCDecoder { frame in onDecoded(index, frame) }
        self.decoder = decoder
        encoder = HEVCEncoder(configuration: .init(averageBitRate: bitRate, realTime: realTime)) { output in
            _ = decoder.decode(output.frame, receivedTimeNanos: HostClock.nowNanos())
        }
        super.init()
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = pixelSize.width
        configuration.height = pixelSize.height
        configuration.pixelFormat = WindowCaptureSession.pixelFormat
        configuration.colorSpaceName = CGColorSpace.displayP3
        configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 90)
        configuration.queueDepth = 4
        configuration.showsCursor = false
        configuration.scalesToFit = false
        stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try? stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    }

    func start() async throws { try await stream?.startCapture() }

    func stop() async {
        try? await stream?.stopCapture()
        encoder.invalidate()
        decoder.invalidate()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                  as? [[SCStreamFrameInfo: Any]])?.first,
              let status = attachments[.status] as? Int, SCFrameStatus(rawValue: status) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              CVPixelBufferGetWidth(pixelBuffer) == pixelSize.width,
              CVPixelBufferGetHeight(pixelBuffer) == pixelSize.height
        else { return }
        let shown = HostClock.nanos(from: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        encoder.encode(CapturedFrame(
            pixelBuffer: pixelBuffer, captureTimeNanos: shown > 0 ? shown : HostClock.nowNanos(),
            deliveredTimeNanos: HostClock.nowNanos(),
            pointSize: CGSize(width: CGFloat(pixelSize.width) / scale, height: CGFloat(pixelSize.height) / scale),
            scale: scale))
    }
}

/// Decoded parts, grouped by the host display frame they belong to.
final class FrameLog: @unchecked Sendable {
    struct Part { let index: Int; let handedOver: UInt64; let decoded: UInt64 }
    private let lock = NSLock()
    private var parts: [UInt64: [Part]] = [:]
    private var recording = false

    func setRecording(_ on: Bool) { lock.withLock { recording = on } }

    func add(_ index: Int, _ frame: DecodedFrame) {
        let decoded = HostClock.nowNanos()
        lock.withLock {
            guard recording else { return }
            // Every strip of one compositor frame carries the same display time.
            let key = frame.captureTimeNanos / 1_000_000
            parts[key, default: []].append(Part(index: index, handedOver: frame.handedOverTimeNanos, decoded: decoded))
        }
    }

    /// Per display frame: latency (ms) and the number of parts.
    func drain() -> [(latency: Double, parts: Int)] {
        lock.withLock {
            defer { parts = [:] }
            return parts.values.map { group in
                let start = group.map(\.handedOver).min()!
                let end = group.map(\.decoded).max()!
                return (Double(end - min(start, end)) / 1e6, Set(group.map(\.index)).count)
            }
        }
    }
}

enum TileWorkload: String, CaseIterable {
    case typing, scroll, full
}

@MainActor
final class TileWorkloads {
    private var windows: [NSWindow] = []
    private var timer: Timer?

    func show(_ workload: TileWorkload, onDisplay displayID: CGDirectDisplayID) {
        close()
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        } ?? NSScreen.main!
        let frame = screen.visibleFrame
        switch workload {
        case .typing:
            let window = NSWindow(contentRect: NSRect(x: frame.midX - 200, y: frame.maxY - 160, width: 400, height: 60),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "typing"
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 20)
            label.frame = NSRect(x: 12, y: 16, width: 376, height: 28)
            window.contentView?.addSubview(label)
            window.isReleasedWhenClosed = false
            window.orderFrontRegardless()
            windows = [window]
            let text = "The quick brown fox jumps over the lazy dog. "
            // ~12 keystrokes a second.
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { _ in
                MainActor.assumeIsolated {
                    label.stringValue = String(text.prefix((label.stringValue.count + 1) % text.count))
                }
            }
        case .scroll:
            windows = [SyntheticWorkloadWindow.open(size: CGSize(width: 900, height: 600),
                                                    origin: CGPoint(x: frame.minX + 40, y: frame.minY + 40))]
        case .full:
            windows = [SyntheticWorkloadWindow.open(size: CGSize(width: frame.width, height: frame.height - 40),
                                                    origin: frame.origin)]
        }
    }

    func close() {
        timer?.invalidate()
        timer = nil
        for window in windows { window.orderOut(nil) }
        windows = []
    }
}

func runTileBench(seconds: Double, strips: Int, realTime: Bool) async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let mainID = CGMainDisplayID()
    guard let display = content.displays.first(where: { $0.displayID == mainID }),
          let mode = CGDisplayCopyDisplayMode(mainID) else { print("no main display"); exit(1) }
    let scale = CGFloat(mode.pixelWidth) / CGFloat(mode.width)
    let size = display.frame.size
    var chip = [CChar](repeating: 0, count: 64), length = 64
    sysctlbyname("machdep.cpu.brand_string", &chip, &length, nil, 0)
    print("\(String(cString: chip)), display \(Int(size.width))×\(Int(size.height)) pt @\(Int(scale))x, \(seconds) s per run")
    print("latency = SCK handed the frame over → every changed part decoded (no network)")
    let workloads = await MainActor.run { TileWorkloads() }

    for workload in TileWorkload.allCases {
        await MainActor.run { workloads.show(workload, onDisplay: mainID) }
        try await Task.sleep(for: .milliseconds(700))
        for count in [1, strips] {
            // Strip heights in whole points, even pixel counts.
            let height = (size.height / CGFloat(count)).rounded(.down)
            let log = FrameLog()
            let pipelines = (0..<count).map { index in
                let y = CGFloat(index) * height
                let rect = CGRect(x: 0, y: y, width: size.width,
                                  height: index == count - 1 ? size.height - y : height)
                return RegionPipeline(index: index, display: display, sourceRect: rect, scale: scale,
                                      bitRate: 60_000_000 / count, realTime: realTime) { log.add($0, $1) }
            }
            for pipeline in pipelines { try await pipeline.start() }
            try await Task.sleep(for: .seconds(1)) // keyframes, warm-up
            log.setRecording(true)
            try await Task.sleep(for: .seconds(seconds))
            log.setRecording(false)
            for pipeline in pipelines { await pipeline.stop() }
            let frames = log.drain()
            let latencies = frames.map(\.latency).sorted()
            guard !latencies.isEmpty else { print("\(workload) ×\(count): no frames"); continue }
            let parts = Double(frames.map(\.parts).reduce(0, +)) / Double(frames.count)
            print(String(format: "%-6@ %d part%@: %5.1f fps  latency p50 %5.2f  p95 %5.2f ms  parts/frame %.2f",
                         workload.rawValue, count, count == 1 ? " " : "s",
                         Double(frames.count) / seconds, latencies[latencies.count / 2],
                         latencies[Int(Double(latencies.count - 1) * 0.95)], parts))
            try await Task.sleep(for: .milliseconds(500))
        }
    }
    await MainActor.run { workloads.close() }
}
