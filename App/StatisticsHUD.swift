import AnyRemoteMedia
import AnyRemoteWire
import AppKit

/// The statistics panel over a remote window or desktop: how sharp, how
/// fast and how late the picture is, where the delay comes from, and the
/// last minute of latency as a bar graph.
///
/// It is drawn into an image that the video layer composites into its frames
/// (see `VideoFrameLayer.setOverlay`), never as a view over the video.
@MainActor
final class StatisticsHUD {
    /// One second's readings.
    struct Reading {
        var title: String
        var viewer: PipelineStats.Summary
        var host: HostStreamReport?
        /// Control round trip, milliseconds.
        var roundTrip: Double?
        /// No video datagram gets through (a firewall or filter on UDP),
        /// although the control connection works.
        var videoBlocked = false
    }

    private static let width: CGFloat = 236
    private static let rowHeight: CGFloat = 16
    private static let padding: CGFloat = 10
    private static let graphHeight: CGFloat = 34
    private static let graphSeconds = 60

    /// Latency per second, oldest first; nil while unknown.
    private var history: [Double?] = []
    private var last: Reading?
    private weak var layer: VideoFrameLayer?
    /// The video's backing scale, so the text is sharp.
    private let scale: () -> CGFloat
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    init(layer: VideoFrameLayer, scale: @escaping () -> CGFloat) {
        self.layer = layer
        self.scale = scale
        observer = NotificationCenter.default.addObserver(
            forName: .statisticsPreferenceChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.show() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Records a second and shows it if the panel is on. Call every second,
    /// shown or not, so the graph is already filled when it is turned on.
    func update(_ reading: Reading) {
        history.append(ConnectionStatus.latency(viewer: reading.viewer, host: reading.host,
                                                roundTrip: reading.roundTrip))
        if history.count > Self.graphSeconds { history.removeFirst(history.count - Self.graphSeconds) }
        last = reading
        show()
    }

    private func show() {
        guard let layer else { return }
        guard StatisticsPreferences.isShown, let last else {
            layer.setOverlay(nil)
            return
        }
        layer.setOverlay(image(last, scale: scale()))
    }

    /// The panel for `reading` at `scale` pixels per point.
    private func image(_ reading: Reading, scale: CGFloat) -> CGImage? {
        let rows = Self.rows(reading)
        let height = Self.padding * 2 + Self.rowHeight * CGFloat(rows.count + 1) + 6 + Self.graphHeight
        let scale = max(1, scale)
        let pixelWidth = Int((Self.width * scale).rounded(.up)), pixelHeight = Int((height * scale).rounded(.up))
        guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                      bytesPerRow: pixelWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        // Top-down points, like a flipped view.
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let bounds = CGRect(x: 0, y: 0, width: Self.width, height: height)
        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor(white: 0, alpha: 0.78).setFill()
        panel.fill()
        NSColor(white: 1, alpha: 0.14).setStroke()
        panel.lineWidth = 1
        panel.stroke()

        let latency = history.last ?? nil
        var y = Self.padding
        let left = Self.padding + 2, right = Self.width - Self.padding - 2
        draw(Self.fitted(reading.title, width: right - left - 90), at: left, y, color: Self.color(latency: latency))
        draw("HEVC 4:4:4", at: right, y, alignedRight: true)
        y += Self.rowHeight
        for row in rows {
            draw(row.label, at: left + (row.indented ? 14 : 0), y, color: row.indented ? Self.secondary : Self.primary)
            draw(row.value, at: right, y, alignedRight: true,
                 color: row.alert ? .systemRed : row.indented ? Self.secondary : Self.primary)
            y += Self.rowHeight
        }
        drawGraph(in: CGRect(x: left, y: y + 6, width: right - left, height: Self.graphHeight))
        context.flush()
        return context.makeImage()
    }

    private struct Row {
        var label: String
        var value: String
        var indented = false
        var alert = false
    }

    private static func rows(_ reading: Reading) -> [Row] {
        let viewer = reading.viewer, host = reading.host
        let receiving = viewer.framesPerSecond > 0
        let size = viewer.pixelSize.width > 0 ? "\(viewer.pixelSize.width)×\(viewer.pixelSize.height)" : "–"
        var rows = [Row(label: size, value: String(format: "%.0f fps", viewer.framesPerSecond))]
        if reading.videoBlocked {
            rows.append(Row(label: String(localized: "Video"), value: String(localized: "Not arriving"), alert: true))
        }
        let total = ConnectionStatus.latency(viewer: viewer, host: host, roundTrip: reading.roundTrip)
        rows.append(Row(label: String(localized: "Latency"), value: milliseconds(total)))
        rows.append(Row(label: String(localized: "Other Mac"),
                        value: milliseconds(host.map { $0.waitP50 + $0.encodeP50 }), indented: true))
        rows.append(Row(label: String(localized: "Network"), value: milliseconds(reading.roundTrip.map { $0 / 2 }),
                        indented: true))
        rows.append(Row(label: String(localized: "This Mac"),
                        value: milliseconds(receiving ? (viewer.p50[.decode] ?? 0) + (viewer.p50[.present] ?? 0) : nil),
                        indented: true))
        rows.append(Row(label: String(localized: "Bitrate"), value: String(format: "%.1f Mbps", viewer.megabitsPerSecond)))
        rows.append(Row(label: String(localized: "Target"),
                        value: host.map { String(format: "%.0f Mbps", Double($0.bitRate) / 1_000_000) } ?? "–",
                        indented: true))
        let sent = viewer.framesPerSecond + Double(viewer.droppedFrames)
        let loss = sent > 0 ? Double(viewer.droppedFrames) / sent * 100 : 0
        rows.append(Row(label: String(localized: "Frame Loss"), value: String(format: "%.1f%%", loss)))
        rows.append(Row(label: String(localized: "Stutters"), value: "\(viewer.hitches)"))
        return rows
    }

    private static func milliseconds(_ value: Double?) -> String {
        guard let value else { return "–" }
        return value < 1 ? "<1 ms" : String(format: "%.0f ms", value)
    }

    /// Green while quick, yellow on the way to slow, red once the connection
    /// counts as slow (`ConnectionStatus.slowLatency`).
    private static func color(latency: Double?) -> NSColor {
        guard let latency else { return Self.secondary }
        if latency < ConnectionStatus.slowLatency * 0.6 { return .systemGreen }
        return latency < ConnectionStatus.slowLatency ? .systemYellow : .systemRed
    }

    // The panel is always dark, whatever the appearance.
    private static let primary = NSColor(white: 0.95, alpha: 1)
    private static let secondary = NSColor(white: 0.62, alpha: 1)

    private static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium)

    private static func fitted(_ text: String, width: CGFloat) -> String {
        var text = text
        while text.count > 1, (text as NSString).size(withAttributes: [.font: font]).width > width {
            text = String(text.dropLast(2)) + "…"
        }
        return text
    }

    private func draw(_ text: String, at x: CGFloat, _ y: CGFloat, alignedRight: Bool = false,
                      color: NSColor = primary) {
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: color]
        let string = text as NSString
        let width = alignedRight ? string.size(withAttributes: attributes).width : 0
        string.draw(at: CGPoint(x: x - width, y: y), withAttributes: attributes)
    }

    /// The last minute of latency, one bar a second, newest on the right.
    private func drawGraph(in rect: CGRect) {
        NSColor(white: 1, alpha: 0.06).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        let guide = NSBezierPath()
        let slowY = rect.maxY - rect.height * min(1, ConnectionStatus.slowLatency / ceiling)
        guide.move(to: CGPoint(x: rect.minX, y: slowY))
        guide.line(to: CGPoint(x: rect.maxX, y: slowY))
        guide.setLineDash([2, 3], count: 2, phase: 0)
        NSColor(white: 1, alpha: 0.18).setStroke()
        guide.lineWidth = 0.5
        guide.stroke()
        let slot = rect.width / CGFloat(Self.graphSeconds)
        for (index, sample) in history.enumerated() {
            guard let sample else { continue }
            let height = max(1, rect.height * min(1, sample / ceiling))
            let x = rect.maxX - slot * CGFloat(history.count - index)
            Self.color(latency: sample).withAlphaComponent(0.9).setFill()
            CGRect(x: x + 0.5, y: rect.maxY - height, width: max(1, slot - 1), height: height).fill()
        }
    }

    /// The graph's top: twice the slow threshold, or the worst second if higher.
    private var ceiling: Double {
        max(ConnectionStatus.slowLatency * 2, history.compactMap { $0 }.max() ?? 0)
    }
}
