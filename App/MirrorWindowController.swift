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
    /// Host title bar buttons (relative to the host window's top-left).
    var controls: WindowControls?
    private var pressedControl: Control?
    private var adoptingRemoteSize = false
    private var inFullScreenTransition = false

    private enum Control { case close, minimize, zoom, fullScreen, letterbox }
    private var statisticsTimer: Timer?
    private var remotePointSize: CGSize
    private var remoteScale = 0
    private var lastResizeSent: CFTimeInterval = 0
    private var awaitingResize = false
    private var hasPresented = false
    private var ended = false

    // Press tracking: the host window may move under a drag (title bar).
    private var pressScreenTopLeft: NSPoint?
    private var pressHostFrame: CGRect?
    private var pressMouse: NSPoint?
    /// The user is dragging this window by an area the host app treats as
    /// draggable; the host window stays put.
    private var localDrag = false
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
        window.collectionBehavior.insert(.fullScreenPrimary)
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
        let label = NSTextField(wrappingLabelWithString: "⚠︎ " + text + " " + String(localized: "Grant it in AnyRemote › Settings on that Mac."))
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
        // The host window moving under a press means the app started a
        // window drag. Drag this window instead; the host puts its window back.
        if let pressHostFrame, !localDrag, frame.size == pressHostFrame.size, frame.origin != pressHostFrame.origin {
            beginLocalDrag()
        }
    }

    private func beginLocalDrag() {
        guard let pressMouse else { return }
        localDrag = true
        // End the host's drag where it began.
        sendInput(.mouseUp(point: hostPoint(forScreenPoint: pressMouse), button: .left, buttonNumber: 0,
                           clickCount: 1, modifiers: 0))
        continueLocalDrag(at: NSEvent.mouseLocation)
    }

    @discardableResult
    func continueLocalDrag(at point: NSPoint) -> Bool {
        guard localDrag, let window, let pressMouse, let pressWindowOrigin else { return false }
        window.setFrameOrigin(NSPoint(x: pressWindowOrigin.x + point.x - pressMouse.x,
                                      y: pressWindowOrigin.y + point.y - pressMouse.y))
        return true
    }

    func finishLocalDrag() -> Bool {
        guard localDrag else { return false }
        localDrag = false
        return true
    }

    func hostResizeApplied(_ size: CGSize) {
        awaitingResize = false
        guard let window, !window.inLiveResize, !isFullScreen, !inFullScreenTransition else { return }
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
        pressHostFrame = stream.frame
        pressWindowOrigin = window?.frame.origin
        pressMouse = NSEvent.mouseLocation
    }

    func pressEnded() {
        pressScreenTopLeft = nil
        pressHostFrame = nil
        pressWindowOrigin = nil
        pressMouse = nil
        localDrag = false
    }

    private var surfaceScreenTopLeft: NSPoint {
        guard let window else { return .zero }
        let rect = window.convertToScreen(surface.convert(videoRect, to: nil))
        return NSPoint(x: rect.minX, y: rect.maxY)
    }

    private var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    /// Where the video is drawn in the surface (flipped coordinates). It fills
    /// the window, except in full screen when the host window couldn't take
    /// the screen's size: then it is centered 1:1, or scaled down to fit.
    private var videoRect: CGRect {
        let bounds = surface.bounds
        guard isFullScreen, remotePointSize.width > 0, remotePointSize.height > 0 else { return bounds }
        var size = remotePointSize
        if size.width > bounds.width || size.height > bounds.height {
            let scale = min(bounds.width / size.width, bounds.height / size.height)
            size = CGSize(width: size.width * scale, height: size.height * scale)
        }
        return CGRect(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded(),
                      width: size.width, height: size.height)
    }

    private func updateVideoGravity() {
        let bounds = surface.bounds
        let fits = remotePointSize.width <= bounds.width && remotePointSize.height <= bounds.height
        surface.frameLayer.contentsGravity = !isFullScreen ? .resize : (fits ? .center : .resizeAspect)
    }

    /// Host points per local point (1 except while sizes disagree mid-resize).
    private var currentScale: CGSize {
        let local = videoRect.size
        guard local.width > 0, local.height > 0 else { return CGSize(width: 1, height: 1) }
        return CGSize(width: remotePointSize.width / local.width, height: remotePointSize.height / local.height)
    }

    // MARK: Title bar buttons

    func beginLocalPress(at point: NSPoint) -> Bool {
        pressedControl = control(at: point)
        log.debug("local press \(String(describing: self.pressedControl), privacy: .public) at \(String(describing: self.hostPoint(forScreenPoint: point)), privacy: .public) controls \(String(describing: self.controls), privacy: .public)")
        return pressedControl != nil
    }

    func endLocalPress(at point: NSPoint) {
        guard let pressed = pressedControl else { return }
        pressedControl = nil
        // Like a real button: only a release over the same button counts.
        guard control(at: point) == pressed else { return }
        perform(pressed, option: NSEvent.modifierFlags.contains(.option))
    }

    private func control(at screenPoint: NSPoint) -> Control? {
        guard let window else { return nil }
        let local = surface.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        if !videoRect.contains(local) { return .letterbox }
        guard let controls else { return nil }
        let point = hostPoint(forScreenPoint: screenPoint)
        let candidates: [(CGRect?, Control)] = [(controls.close, .close), (controls.minimize, .minimize),
                                                (controls.zoom, .zoom), (controls.fullScreen, .fullScreen)]
        return candidates.first { $0.0?.insetBy(dx: -1, dy: -1).contains(point) ?? false }?.1
    }

    private func perform(_ control: Control, option: Bool) {
        switch control {
        case .close:
            connection.client.send(.windowAction(streamID: streamID, action: .close))
        case .minimize:
            window?.miniaturize(nil)
        case .zoom, .fullScreen:
            // As on a real window: click for full screen, ⌥-click to zoom.
            if option, !isFullScreen { window?.zoom(nil) } else { window?.toggleFullScreen(nil) }
        case .letterbox:
            break
        }
    }

    /// ⌘M and ⌃⌘F act on this window rather than the host's.
    func handleWindowShortcut(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        let relevant = flags.intersection([.command, .control, .option, .shift])
        if keyCode == 46, relevant == .command { window?.miniaturize(nil); return true }           // ⌘M
        if keyCode == 3, relevant == [.command, .control] { window?.toggleFullScreen(nil); return true } // ⌃⌘F
        return false
    }

    /// The host app minimized or went full screen by itself (menu, title bar
    /// double-click); the host has already undone it on its side.
    func applyHostStateRequest(_ request: HostWindowStateRequest) {
        guard let window else { return }
        switch request {
        case .minimize:
            if !window.isMiniaturized { window.miniaturize(nil) }
        case .enterFullScreen:
            if !isFullScreen { window.toggleFullScreen(nil) }
        }
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
        updateVideoGravity()
        guard let window, !window.inLiveResize, !awaitingResize, !isFullScreen, !inFullScreenTransition else { return }
        adoptRemoteSize(size)
    }

    /// Resizes the local window to the host size, keeping the top-left corner fixed.
    private func adoptRemoteSize(_ size: CGSize) {
        guard let window else { return }
        let current = surface.bounds.size
        guard abs(current.width - size.width) >= 1 || abs(current.height - size.height) >= 1 else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        adoptingRemoteSize = true
        window.setFrame(frame, display: true)
        adoptingRemoteSize = false
    }

    /// Asks the host window to take `size` (points), as a finished live resize would.
    func requestHostResize(_ size: CGSize) {
        awaitingResize = true
        connection.client.send(.resize(streamID: streamID, size: size))
    }

    func windowDidResize(_ notification: Notification) {
        guard let window else { return }
        updateVideoGravity()
        // Zoom and other programmatic resizes: the host follows once.
        if !window.inLiveResize {
            if !adoptingRemoteSize, !inFullScreenTransition, !isFullScreen { requestHostResize(surface.bounds.size) }
            return
        }
        // ~60 Hz is plenty; the host coalesces anyway.
        let now = CACurrentMediaTime()
        guard now - lastResizeSent >= 1.0 / 60 else { return }
        lastResizeSent = now
        requestHostResize(surface.bounds.size)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        requestHostResize(surface.bounds.size)
    }

    // Full screen: the host window takes the screen's size, so it stays 1:1.
    func windowWillEnterFullScreen(_ notification: Notification) { inFullScreenTransition = true }
    func windowWillExitFullScreen(_ notification: Notification) { inFullScreenTransition = true }

    func windowDidEnterFullScreen(_ notification: Notification) {
        inFullScreenTransition = false
        updateVideoGravity()
        requestHostResize(surface.bounds.size)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        inFullScreenTransition = false
        updateVideoGravity()
        requestHostResize(surface.bounds.size)
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) { inFullScreenTransition = false }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { inFullScreenTransition = false }

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
