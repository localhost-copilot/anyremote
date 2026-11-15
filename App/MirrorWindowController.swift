import AnyRemoteClient
import AnyRemoteMedia
import AnyRemoteWire
import AppKit
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Mirror")

/// Shows one host window as a local window.
///
/// The local window adopts the host window's point size, so frames are
/// presented 1:1 when both sides share a backing scale. Resizing the local
/// window resizes the host window; the host's actual (possibly clamped) size
/// is adopted when the live resize ends. Dragging the host window's own title
/// bar moves the host window, and the local window follows it.
@MainActor
final class MirrorWindowController: NSWindowController, NSWindowDelegate, RemoteInputSink {
    private(set) var stream: StreamDescription
    unowned let connection: HostConnection
    var onClose: (() -> Void)?
    var hostReport: HostStreamReport?

    let surface = RemoteSurfaceView()
    let stats = PipelineStats()
    private let statisticsLabel = NSTextField(labelWithString: "")
    private var noticeView: NSView?
    private var statisticsTimer: Timer?
    private var remotePointSize: CGSize
    private var remoteScale = 0
    private var lastResizeSent: CFTimeInterval = 0
    private var awaitingResize = false
    private var hasPresented = false
    private var ended = false

    // Press tracking: the host window may move under a drag (title bar).
    private var pressScreenTopLeft: NSPoint?
    private var pressHostOrigin: CGPoint?
    private var pressWindowOrigin: NSPoint?
    private var pressScale: CGSize = CGSize(width: 1, height: 1)

    private(set) var remoteMenus: [MenuNode] = []
    private(set) var remoteApplicationName = ""
    var onMenuBarChange: ((MirrorWindowController) -> Void)?

    var streamID: UInt16 { stream.streamID }
    var windowID: UInt32 { stream.windowID }

    init(connection: HostConnection, description: StreamDescription) {
        self.connection = connection
        self.stream = description
        self.remotePointSize = stream.frame.size

        let window = MirrorWindow(
            contentRect: NSRect(origin: .zero, size: stream.frame.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.contentMinSize = NSSize(width: 120, height: 80)
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenNone)
        super.init(window: window)
        window.delegate = self
        updateTitle()

        surface.frame = NSRect(origin: .zero, size: stream.frame.size)
        surface.autoresizingMask = [.width, .height]
        surface.sink = self
        surface.frameLayer.stats = stats
        surface.frameLayer.remoteClock = connection.client.clock
        window.contentView = surface
        window.hideTitlebarChrome()
        window.makeFirstResponder(surface)

        configureStatisticsLabel()
        surface.frameLayer.onGeometryChange = { [weak self] width, height, scale in
            self?.remoteGeometryChanged(pixelWidth: width, pixelHeight: height, scale: scale)
        }
        placeInitially()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func start() {
        let layer = surface.frameLayer
        connection.client.attach(streamID: streamID, stats: stats) { frame in layer.enqueue(frame) }
        statisticsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatistics() }
        }
        connection.client.send(.focus(streamID: streamID))
        connection.client.send(.requestMenuBar(streamID: streamID))
        updateNotice()
    }

    /// A banner along the bottom edge while the host can't take input.
    func updateNotice() {
        let text = connection.inputBlockedReason ?? connection.captureBlockedReason
        noticeView?.removeFromSuperview()
        noticeView = nil
        guard let text, let content = window?.contentView else { return }
        let label = NSTextField(wrappingLabelWithString: "⚠︎ " + text + " 在那台 Mac 上打开 AnyRemote › 设置 授权。")
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
        content.addSubview(background)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -8),
            background.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            background.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            background.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -24),
            background.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
        noticeView = background
    }

    private func updateTitle() {
        let title = stream.title.isEmpty ? stream.applicationName : stream.title
        window?.title = "\(title) — \(connection.hostName)"
    }

    /// Opens where the host window sits relative to its display, when that fits locally.
    private func placeInitially() {
        guard let window, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        var origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        if let display = connection.welcome?.displays.first(where: { $0.frame.intersects(stream.frame) }) {
            let relativeX = stream.frame.minX - display.frame.minX
            let relativeTop = stream.frame.minY - display.frame.minY
            let candidate = NSPoint(x: visible.minX + relativeX, y: visible.maxY - relativeTop - size.height)
            if visible.contains(NSRect(origin: candidate, size: size)) { origin = candidate }
        }
        window.setFrameOrigin(origin)
    }

    // MARK: Host events

    func hostFrameChanged(_ frame: CGRect, title: String) {
        let oldTitle = stream.title
        stream.frame = frame
        stream.title = title
        if title != oldTitle { updateTitle() }
        // Follow host-side moves only while the user drags (title bar drags).
        if let pressHostOrigin, let pressWindowOrigin, let window {
            let dx = frame.minX - pressHostOrigin.x
            let dy = frame.minY - pressHostOrigin.y
            window.setFrameOrigin(NSPoint(x: pressWindowOrigin.x + dx, y: pressWindowOrigin.y - dy))
        }
    }

    func hostResizeApplied(_ size: CGSize) {
        awaitingResize = false
        guard let window, !window.inLiveResize else { return }
        adoptRemoteSize(size)
    }

    func hostEnded(reason: String) {
        log.notice("stream ended: \(reason, privacy: .public)")
        ended = true
        close()
    }

    func hostDisconnected(reason: String?) {
        ended = true
        close()
    }

    func cursorChanged() { surface.refreshCursor() }

    func menuBarArrived(applicationName: String, menus: [MenuNode]) {
        remoteApplicationName = applicationName
        remoteMenus = menus
        onMenuBarChange?(self)
    }

    func refreshMenuBar() {
        connection.client.send(.requestMenuBar(streamID: streamID))
    }

    func performMenuItem(path: [Int]) {
        connection.client.send(.performMenuItem(streamID: streamID, path: path))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refreshMenuBar() }
    }

    // MARK: RemoteInputSink

    var remoteCursor: NSCursor? { connection.currentCursor }

    func hostPoint(forScreenPoint point: NSPoint) -> CGPoint {
        let topLeft = pressScreenTopLeft ?? surfaceScreenTopLeft
        let scale = pressScreenTopLeft == nil ? currentScale : pressScale
        return CGPoint(x: (point.x - topLeft.x) * scale.width, y: (topLeft.y - point.y) * scale.height)
    }

    func sendInput(_ event: InputEvent) {
        connection.client.send(.input(streamID: streamID, event))
    }

    func pressBegan() {
        pressScreenTopLeft = surfaceScreenTopLeft
        pressScale = currentScale
        pressHostOrigin = stream.frame.origin
        pressWindowOrigin = window?.frame.origin
    }

    func pressEnded() {
        pressScreenTopLeft = nil
        pressHostOrigin = nil
        pressWindowOrigin = nil
    }

    private var surfaceScreenTopLeft: NSPoint {
        guard let window else { return .zero }
        let rect = window.convertToScreen(surface.convert(surface.bounds, to: nil))
        return NSPoint(x: rect.minX, y: rect.maxY)
    }

    /// Host points per local point (1 except while sizes disagree mid-resize).
    private var currentScale: CGSize {
        let local = surface.bounds.size
        guard local.width > 0, local.height > 0 else { return CGSize(width: 1, height: 1) }
        return CGSize(width: remotePointSize.width / local.width, height: remotePointSize.height / local.height)
    }

    /// Screen frame (Cocoa coordinates) of a host rect given in host global points.
    func localScreenFrame(forHostFrame hostFrame: CGRect) -> NSRect {
        let topLeft = surfaceScreenTopLeft
        let scale = currentScale
        let x = topLeft.x + (hostFrame.minX - stream.frame.minX) / scale.width
        let top = topLeft.y - (hostFrame.minY - stream.frame.minY) / scale.height
        let size = CGSize(width: hostFrame.width / scale.width, height: hostFrame.height / scale.height)
        return NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
    }

    // MARK: Statistics

    private func configureStatisticsLabel() {
        statisticsLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        statisticsLabel.textColor = .white
        statisticsLabel.backgroundColor = NSColor.black.withAlphaComponent(0.65)
        statisticsLabel.drawsBackground = true
        statisticsLabel.maximumNumberOfLines = 0
        statisticsLabel.lineBreakMode = .byTruncatingTail
        // The overlay must never influence the window size.
        statisticsLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        statisticsLabel.setContentCompressionResistancePriority(.init(1), for: .vertical)
        statisticsLabel.translatesAutoresizingMaskIntoConstraints = false
        statisticsLabel.isHidden = ProcessInfo.processInfo.environment["ANYREMOTE_STATS"] != "1"
        surface.addSubview(statisticsLabel)
        NSLayoutConstraint.activate([
            statisticsLabel.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 8),
            statisticsLabel.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -8),
            statisticsLabel.trailingAnchor.constraint(lessThanOrEqualTo: surface.trailingAnchor, constant: -8),
        ])
    }

    func toggleStatistics() { statisticsLabel.isHidden.toggle() }

    private func updateStatistics() {
        let summary = stats.drain()
        let backing = window?.backingScaleFactor ?? 0
        let viewPixels = surface.convertToBacking(surface.bounds).size
        let native = Int(viewPixels.width) == summary.pixelSize.width && Int(viewPixels.height) == summary.pixelSize.height
        var lines = ["viewer \(summary)"]
        if let report = hostReport {
            lines.append(String(format: "host capture %.2f wait %.2f encode %.2f/%.2f · %.0f Mbps target",
                                report.captureP50, report.waitP50, report.encodeP50, report.encodeP95,
                                Double(report.bitRate) / 1_000_000))
        }
        let rtt = connection.client.roundTripMilliseconds.map { String(format: "%.2f ms", $0) } ?? "–"
        lines.append("""
        host \(Int(remotePointSize.width))×\(Int(remotePointSize.height))pt @\(remoteScale)x · \
        local \(Int(viewPixels.width))×\(Int(viewPixels.height))px @\(Int(backing))x · \
        \(native ? "1:1 native" : "scaled") · rtt \(rtt)
        """)
        let text = lines.joined(separator: "\n")
        statisticsLabel.stringValue = text
        if ProcessInfo.processInfo.environment["ANYREMOTE_STATS_STDOUT"] == "1" {
            print(text.replacingOccurrences(of: "\n", with: " | "))
        }
    }

    // MARK: Geometry

    private func remoteGeometryChanged(pixelWidth: Int, pixelHeight: Int, scale: Int) {
        guard scale > 0 else { return }
        remoteScale = scale
        let size = CGSize(width: CGFloat(pixelWidth) / CGFloat(scale), height: CGFloat(pixelHeight) / CGFloat(scale))
        remotePointSize = size
        hasPresented = true
        guard let window, !window.inLiveResize, !awaitingResize else { return }
        adoptRemoteSize(size)
    }

    /// Resizes the local window to the host size, keeping the top-left corner fixed.
    private func adoptRemoteSize(_ size: CGSize) {
        guard let window else { return }
        let current = surface.bounds.size
        guard abs(current.width - size.width) >= 1 || abs(current.height - size.height) >= 1 else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true)
    }

    /// Asks the host window to take `size` (points), as a finished live resize would.
    func requestHostResize(_ size: CGSize) {
        awaitingResize = true
        connection.client.send(.resize(streamID: streamID, size: size))
    }

    func windowDidResize(_ notification: Notification) {
        guard let window, window.inLiveResize else { return }
        // ~60 Hz is plenty; the host coalesces anyway.
        let now = CACurrentMediaTime()
        guard now - lastResizeSent >= 1.0 / 60 else { return }
        lastResizeSent = now
        requestHostResize(surface.bounds.size)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        requestHostResize(surface.bounds.size)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        connection.client.send(.focus(streamID: streamID))
        refreshMenuBar()
        onMenuBarChange?(self)
    }

    func windowWillClose(_ notification: Notification) {
        statisticsTimer?.invalidate()
        statisticsTimer = nil
        onClose?()
        onClose = nil
    }
}

/// A titled window whose title bar chrome is hidden and passes clicks
/// through, so the host window's own title bar and toolbar receive them.
final class MirrorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func hideTitlebarChrome() {
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        // NSTitlebarContainerView would otherwise turn clicks in the top
        // ~28 pt into local window drags.
        standardWindowButton(.closeButton)?.superview?.superview?.isHidden = true
    }
}
