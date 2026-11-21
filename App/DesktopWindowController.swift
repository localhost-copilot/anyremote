import AnyRemoteClient
import AnyRemoteMedia
import AnyRemoteWire
import AppKit
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Desktop")

/// Shows one whole host display (the full desktop) in a local window, over
/// AnyRemote's own protocol: the same HEVC 4:4:4 stream, encryption and
/// input path as window mirrors, so no second app is needed.
///
/// With "Fit Desktop to Window" (dynamic resolution, the default) the host's
/// desktop takes the window's size: resize the window, or make it full
/// screen, and the host rearranges for it, so the picture is always 1:1.
/// Otherwise the picture keeps the display's aspect ratio and is scaled to
/// the window (area-filtered when smaller). Clicks, scrolling and keys
/// go to the host at the matching display point; the host's cursor is drawn
/// locally, so pointer motion has no network latency.
@MainActor
final class DesktopWindowController: NSWindowController, NSWindowDelegate, RemoteInputSink, RemoteKeyTarget,
                                     RemoteDragTarget {
    private(set) var stream: StreamDescription
    unowned let connection: HostConnection
    var onClose: (() -> Void)?
    var hostReport: HostStreamReport?

    let surface = RemoteSurfaceView()
    let stats = PipelineStats()
    /// Drawn into the video frames (a view on top of the video made full screen stutter on every update).
    private lazy var statisticsHUD = StatisticsHUD(layer: surface.frameLayer) { [weak self] in
        self?.window?.backingScaleFactor ?? 2
    }
    private var noticeView: NSView?
    private var statisticsTimer: Timer?
    let connectionStatus = ConnectionStatus()
    /// The display's size in host points.
    private var remotePointSize: CGSize
    private var remoteScale = 0
    private var pressTopLeft: NSPoint?
    private var pressScale: CGSize?
    /// Dynamic resolution: the last size asked of the host, and a pending request.
    private var requestedSize: CGSize?
    private var sizeRequest: Task<Void, Never>?
    private var preferencesObserver: NSObjectProtocol?

    var streamID: UInt16 { stream.streamID }
    var displayID: UInt32 { stream.windowID }

    init(connection: HostConnection, description: StreamDescription) {
        self.connection = connection
        self.stream = description
        self.remotePointSize = description.frame.size

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: description.frame.size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentMinSize = NSSize(width: 320, height: 200)
        super.init(window: window)
        window.delegate = self

        surface.frame = NSRect(origin: .zero, size: description.frame.size)
        surface.autoresizingMask = [.width, .height]
        surface.sink = self
        surface.frameLayer.stats = stats
        surface.frameLayer.remoteClock = connection.client.clock
        surface.frameLayer.contentsGravity = .resizeAspect
        window.contentView = surface
        window.makeFirstResponder(surface)
        surface.frameLayer.onGeometryChange = { [weak self] width, height, scale in
            self?.remoteGeometryChanged(pixelWidth: width, pixelHeight: height, scale: scale)
        }
        updateTitle()
        applyAspectRatio()
        placeInitially()
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: .desktopPreferencesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesChanged() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func start() {
        let layer = surface.frameLayer
        // Strips arrive as streams of their own; the layer puts them together.
        for id in stream.tileStreamIDs ?? [streamID] {
            connection.client.attach(streamID: id, stats: stats) { frame in layer.enqueue(frame) }
        }
        statisticsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatistics() }
        }
        updateNotice()
        updateTargetSize()
        if DesktopPreferences.fitsWindow { requestWindowSize(after: .zero) }
    }

    private func updateTitle() {
        let displays = connection.listing?.displays ?? connection.welcome?.displays ?? []
        if displays.count > 1 {
            window?.title = "\(connection.hostName) — \(stream.title)"
        } else {
            window?.title = connection.hostName
        }
        NotificationCenter.default.post(name: .mirrorsChanged, object: self)
    }

    /// Opens at the display's own size when that fits on this screen (1:1),
    /// otherwise as large as fits, centered.
    private func placeInitially() {
        guard let window, let screen = NSScreen.main else { return }
        let size = Self.fittedContentSize(remotePointSize, in: screen.visibleFrame.insetBy(dx: 20, dy: 20), window: window)
        window.setContentSize(size)
        window.center()
    }

    private static func fittedContentSize(_ size: CGSize, in area: NSRect, window: NSWindow) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: 960, height: 600) }
        // Room for the title bar.
        let chrome = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 100, height: 100)).height - 100
        let available = CGSize(width: area.width, height: area.height - chrome)
        let factor = min(1, available.width / size.width, available.height / size.height)
        return CGSize(width: (size.width * factor).rounded(.down), height: (size.height * factor).rounded(.down))
    }

    /// Without dynamic resolution the window keeps the display's shape.
    private func applyAspectRatio() {
        guard let window else { return }
        if DesktopPreferences.fitsWindow {
            window.contentResizeIncrements = NSSize(width: 1, height: 1)
        } else if remotePointSize.width > 0, remotePointSize.height > 0 {
            window.contentAspectRatio = remotePointSize
        }
    }

    // MARK: Dynamic resolution

    private func preferencesChanged() {
        applyAspectRatio()
        if DesktopPreferences.fitsWindow {
            requestWindowSize(after: .zero)
        } else if requestedSize != nil {
            sizeRequest?.cancel()
            requestedSize = nil
            connection.client.setDesktopSize(streamID: streamID, size: nil)
        } else {
            keepAspect()
        }
    }

    /// Asks the host for a desktop of the window's size, once resizing settles.
    private func requestWindowSize(after delay: Duration = .milliseconds(400)) {
        guard DesktopPreferences.fitsWindow else { return }
        sizeRequest?.cancel()
        sizeRequest = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self, DesktopPreferences.fitsWindow,
                  let window, !window.inLiveResize else { return }
            let bounds = surface.bounds.size
            let size = CGSize(width: (bounds.width / 2).rounded(.down) * 2, height: (bounds.height / 2).rounded(.down) * 2)
            guard size.width >= 2, size.height >= 2, size != requestedSize else { return }
            requestedSize = size
            log.info("desktop size request \(size.debugDescription, privacy: .public)")
            connection.client.setDesktopSize(streamID: streamID, size: size)
        }
    }

    /// The picture is drawn at the window's own pixel size, so scaling down
    /// uses the area filter instead of the compositor's.
    private func updateTargetSize() {
        surface.frameLayer.targetPixelSize = surface.convertToBacking(surface.bounds).size
        surface.frameLayer.redrawLastFrame()
    }

    /// A banner along the bottom edge while the host can't take input or capture.
    func updateNotice() {
        let text = connection.inputBlockedReason ?? connection.captureBlockedReason
        noticeView?.removeFromSuperview()
        noticeView = nil
        guard let text else { return }
        let banner = NoticeBanner.make(text: "⚠︎ " + text + " " + String(localized: "Grant it in AnyRemote › Settings on that Mac."))
        guard let content = window?.contentView else { return }
        content.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            banner.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            banner.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -24),
            banner.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
        noticeView = banner
    }

    // MARK: Host events

    func hostFrameChanged(_ frame: CGRect, title: String) {
        let resized = frame.size != stream.frame.size
        stream.frame = frame
        stream.title = title
        updateTitle()
        if resized {
            remotePointSize = frame.size
            applyAspectRatio()
            if !DesktopPreferences.fitsWindow { keepAspect() }
        }
    }

    func hostEnded(reason: String) {
        log.notice("desktop stream ended: \(reason, privacy: .public)")
        close()
    }

    func cursorChanged() { surface.refreshCursor() }

    private func remoteGeometryChanged(pixelWidth: Int, pixelHeight: Int, scale: Int) {
        guard scale > 0 else { return }
        remoteScale = scale
        let size = CGSize(width: CGFloat(pixelWidth) / CGFloat(scale), height: CGFloat(pixelHeight) / CGFloat(scale))
        guard abs(size.width - remotePointSize.width) >= 1 || abs(size.height - remotePointSize.height) >= 1 else { return }
        remotePointSize = size
        applyAspectRatio()
        if !DesktopPreferences.fitsWindow { keepAspect() }
    }

    /// After the display changed shape, the window takes the new aspect
    /// ratio at about the same width (shrunk to fit the screen if needed).
    private func keepAspect() {
        guard let window, !isFullScreen, remotePointSize.width > 0 else { return }
        let width = surface.bounds.width
        var size = CGSize(width: width, height: (width * remotePointSize.height / remotePointSize.width).rounded())
        if let area = window.screen?.visibleFrame {
            let fitted = Self.fittedContentSize(size, in: area, window: window)
            size = fitted
        }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true)
    }

    // MARK: RemoteInputSink

    var remoteCursor: NSCursor? { connection.currentCursor }

    /// The host's text caret, relative to the stream's top-left corner, and its text's font.
    private(set) var caret: CGRect?
    private var caretTextFont: CaretFont?

    func setCaret(_ rect: CGRect?, font: CaretFont?) {
        guard rect != caret || font != caretTextFont else { return }
        caret = rect
        caretTextFont = font
        surface.composer.caretMoved()
    }

    func caretFont() -> NSFont? {
        guard let caretTextFont else { return nil }
        let size = caretTextFont.size / max(0.01, currentScale.height)
        // The system font's private name doesn't resolve with NSFont(name:).
        return caretTextFont.name.hasPrefix(".") ? .systemFont(ofSize: size)
            : NSFont(name: caretTextFont.name, size: size) ?? .systemFont(ofSize: size)
    }

    func caretScreenRect() -> NSRect? {
        guard let caret else { return nil }
        let topLeft = videoScreenTopLeft
        let scale = currentScale
        let height = caret.height / scale.height
        return NSRect(x: topLeft.x + caret.minX / scale.width, y: topLeft.y - caret.minY / scale.height - height,
                      width: max(1, caret.width / scale.width), height: height)
    }

    private var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    /// Where the picture is drawn in the surface (flipped coordinates): the
    /// display's aspect ratio fitted into the view, centered.
    private var videoRect: CGRect {
        let bounds = surface.bounds
        guard remotePointSize.width > 0, remotePointSize.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let factor = min(bounds.width / remotePointSize.width, bounds.height / remotePointSize.height)
        let size = CGSize(width: remotePointSize.width * factor, height: remotePointSize.height * factor)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private var videoScreenTopLeft: NSPoint {
        guard let window else { return .zero }
        let rect = window.convertToScreen(surface.convert(videoRect, to: nil))
        return NSPoint(x: rect.minX, y: rect.maxY)
    }

    /// Host points per local point.
    private var currentScale: CGSize {
        let local = videoRect.size
        guard local.width > 0, local.height > 0 else { return CGSize(width: 1, height: 1) }
        return CGSize(width: remotePointSize.width / local.width, height: remotePointSize.height / local.height)
    }

    func hostPoint(forScreenPoint point: NSPoint) -> CGPoint {
        let topLeft = pressTopLeft ?? videoScreenTopLeft
        let scale = pressScale ?? currentScale
        let x = (point.x - topLeft.x) * scale.width
        let y = (topLeft.y - point.y) * scale.height
        // Keep the host pointer on this display while dragging past the window's edge.
        return CGPoint(x: min(max(0, x), max(0, remotePointSize.width - 1)),
                       y: min(max(0, y), max(0, remotePointSize.height - 1)))
    }

    /// Development: sees input in place of the host.
    var inputTap: ((InputEvent) -> Void)?

    func sendInput(_ event: InputEvent) {
        if let inputTap { return inputTap(event) }
        connection.client.send(.input(streamID: streamID, event))
    }

    func pressBegan() {
        pressTopLeft = videoScreenTopLeft
        pressScale = currentScale
    }

    func pressEnded() {
        pressTopLeft = nil
        pressScale = nil
    }

    // MARK: RemoteDragTarget

    var dragTarget: (any RemoteDragTarget)? { self }

    /// The desktop's picture shows the host's own drag; past its edge this Mac's drag carries on.
    func takesOverHostDrag(at screenPoint: NSPoint) -> Bool {
        guard let window else { return true }
        return !window.convertToScreen(surface.convert(videoRect, to: nil)).contains(screenPoint)
    }

    var handsOverAtEdge: Bool { true }

    /// Presses on the letterbox bars (full screen on a differently shaped screen) stay here.
    func beginLocalPress(at point: NSPoint) -> Bool {
        guard let window else { return false }
        let local = surface.convert(window.convertPoint(fromScreen: point), from: nil)
        return !videoRect.contains(local)
    }

    // MARK: RemoteKeyTarget

    /// Every key, ⌘M and ⌃⌘F included, belongs to the host's desktop.
    func handleWindowShortcut(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool { false }

    // MARK: Window

    /// The green button's zoom fills the screen (dynamic resolution), or
    /// toggles to the display's own size (1:1) or the largest that fits.
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        if DesktopPreferences.fitsWindow { return newFrame }
        let area = window.screen?.visibleFrame ?? newFrame
        let size = Self.fittedContentSize(remotePointSize, in: area, window: window)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: min(max(area.minX, window.frame.minX), area.maxX - frame.width),
                               y: max(area.minY, window.frame.maxY - frame.height))
        return frame
    }

    func windowDidResize(_ notification: Notification) {
        updateTargetSize()
        if window?.inLiveResize == false { requestWindowSize() }
    }

    func windowDidEndLiveResize(_ notification: Notification) { requestWindowSize() }
    func windowDidEnterFullScreen(_ notification: Notification) { requestWindowSize(after: .milliseconds(100)) }
    func windowDidExitFullScreen(_ notification: Notification) { requestWindowSize(after: .milliseconds(100)) }
    func windowDidChangeBackingProperties(_ notification: Notification) { updateTargetSize() }

    func windowWillClose(_ notification: Notification) {
        sizeRequest?.cancel()
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
        preferencesObserver = nil
        statisticsTimer?.invalidate()
        statisticsTimer = nil
        onClose?()
        onClose = nil
        NotificationCenter.default.post(name: .mirrorsChanged, object: nil)
    }

    // MARK: Statistics

    private func updateStatistics() {
        let summary = stats.drain()
        let backing = window?.backingScaleFactor ?? 0
        let videoPixels = surface.convertToBacking(videoRect).size
        let native = abs(videoPixels.width - CGFloat(summary.pixelSize.width)) < 1
            && abs(videoPixels.height - CGFloat(summary.pixelSize.height)) < 1
        var lines = ["viewer \(summary)"]
        if let report = hostReport {
            lines.append(String(format: "host %@ lead %.2f wait %.2f encode %.2f/%.2f · %.0f Mbps target",
                                report.chip ?? "?", report.captureP50, report.waitP50, report.encodeP50,
                                report.encodeP95, Double(report.bitRate) / 1_000_000))
        }
        let udp = connection.client.datagramCounts
        lines.append("udp in \(udp.received) · unreadable \(udp.unreadable) · keepalive failures \(udp.keepaliveFailures)"
                     + (hostReport?.videoDestination.map { " · host sends video to \($0)" } ?? ""))
        let rtt = connection.client.roundTripMilliseconds.map { String(format: "%.2f ms", $0) } ?? "–"
        let pacing = surface.frameLayer.pacingDescription
        if !pacing.isEmpty { lines.append(pacing) }
        lines.append("""
        desktop \(Int(remotePointSize.width))×\(Int(remotePointSize.height))pt @\(remoteScale)x · \
        shown \(Int(videoPixels.width))×\(Int(videoPixels.height))px @\(Int(backing))x · \
        \(native ? "1:1 native" : "scaled") · rtt \(rtt)
        """)
        if let content = window?.contentView {
            connectionStatus.update(viewer: summary, host: hostReport, roundTrip: connection.client.roundTripMilliseconds,
                                    relayed: connection.isRelayed, in: content)
        }
        lines.append("route \(connection.routeDescription)")
        let text = lines.joined(separator: "\n")
        statisticsHUD.update(.init(title: "\(connection.hostName) · \(connection.routeDescription)", viewer: summary, host: hostReport,
                                   roundTrip: connection.client.roundTripMilliseconds,
                                   videoBlocked: udp.received == 0 || hostReport?.videoDestination == "none"))
        if ProcessInfo.processInfo.environment["ANYREMOTE_STATS_STDOUT"] == "1" {
            print(text.replacingOccurrences(of: "\n", with: " | "))
        }
    }
}

/// The dark rounded banner mirrors and desktops show along their bottom edge.
enum NoticeBanner {
    @MainActor
    static func make(text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.appearance = NSAppearance(named: .vibrantDark)
        background.blendingMode = .withinWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -8),
        ])
        return background
    }
}
