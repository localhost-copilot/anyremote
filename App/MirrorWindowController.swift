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
final class MirrorWindowController: NSWindowController, NSWindowDelegate, RemoteInputSink, RemoteKeyTarget,
                                    RemoteDragTarget {
    private(set) var stream: StreamDescription
    unowned let connection: HostConnection
    var onClose: (() -> Void)?
    var hostReport: HostStreamReport?

    let surface = RemoteSurfaceView()
    let stats = PipelineStats()
    /// Drawn into the video frames (a view on top of the video made full screen stutter on every update).
    private var showsStatistics = ProcessInfo.processInfo.environment["ANYREMOTE_STATS"] == "1"
    private var noticeView: NSView?
    /// Host title bar buttons (relative to the host window's top-left).
    var controls: WindowControls? { didSet { layoutWindowButtons() } }
    /// This window's own buttons, shown over the host's.
    private let windowButtons = WindowButtonGroup()
    /// In full screen the buttons only show while the pointer is at them.
    private var revealsButtonsInFullScreen = false
    private var pressedControl: Control?
    private var adoptingRemoteSize = false
    private var inFullScreenTransition = false
    /// The host window is in full screen (the app's own, such as a web page's
    /// video), and this window is following it.
    private var hostFullScreen = false
    /// This window's full screen began with the host window's.
    private var enteredForHost = false

    private enum Control { case close, minimize, zoom, fullScreen, letterbox }
    private var statisticsTimer: Timer?
    let connectionStatus = ConnectionStatus()
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
        windowButtons.isHidden = true
        surface.addSubview(windowButtons)
        windowButtons.adoptButtons(of: window)
        windowButtons.setAction(#selector(closeHostWindow(_:)), target: self, for: .closeButton)
        windowButtons.onMouseExit = { [weak self] in self?.windowButtonsExited() }
        windowButtons.onButtonsTaken = { [weak self] in self?.layoutWindowButtons() }

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
        let banner = NoticeBanner.make(text: "⚠︎ " + text + " " + String(localized: "Grant it in AnyRemote › Settings on that Mac."))
        content.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            banner.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            banner.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -24),
            banner.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
        noticeView = banner
    }

    private func updateTitle() {
        let title = stream.title.isEmpty ? stream.applicationName : stream.title
        window?.title = "\(title) — \(connection.hostName)"
        NotificationCenter.default.post(name: .mirrorsChanged, object: self)
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
        let topLeft = surfaceScreenTopLeft
        let scale = currentScale
        let height = caret.height / scale.height
        return NSRect(x: topLeft.x + caret.minX / scale.width, y: topLeft.y - caret.minY / scale.height - height,
                      width: max(1, caret.width / scale.width), height: height)
    }

    func hostPoint(forScreenPoint point: NSPoint) -> CGPoint {
        let topLeft = pressScreenTopLeft ?? surfaceScreenTopLeft
        let scale = pressScreenTopLeft == nil ? currentScale : pressScale
        return CGPoint(x: (point.x - topLeft.x) * scale.width, y: (topLeft.y - point.y) * scale.height)
    }

    // MARK: RemoteDragTarget

    var dragTarget: (any RemoteDragTarget)? { self }
    /// The window's picture lacks the host's drag image: this Mac's drag shows it at once.
    func takesOverHostDrag(at screenPoint: NSPoint) -> Bool { true }
    var handsOverAtEdge: Bool { false }

    func sendInput(_ event: InputEvent) {
        if case let .mouseMove(point, _, _) = event, isFullScreen { revealButtonsInFullScreen(near: point) }
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

    /// Puts this window's buttons on the host window's (host points → surface).
    private func layoutWindowButtons() {
        guard let window else { return }
        // AppKit moves the buttons between title bars during full screen
        // transitions; taking them then breaks the transition.
        guard !inFullScreenTransition else {
            windowButtons.isHidden = true
            return
        }
        windowButtons.adoptButtons(of: window)
        guard let controls, !isFullScreen || revealsButtonsInFullScreen else {
            windowButtons.isHidden = true
            return
        }
        let scale = currentScale
        let origin = videoRect.origin
        func center(_ rect: CGRect?) -> CGPoint? {
            rect.map { CGPoint(x: origin.x + $0.midX / scale.width, y: origin.y + $0.midY / scale.height) }
        }
        windowButtons.isHidden = false
        windowButtons.place(centers: [.closeButton: center(controls.close),
                                      .miniaturizeButton: center(controls.minimize),
                                      .zoomButton: center(controls.zoom ?? controls.fullScreen)].compactMapValues { $0 })
    }

    /// The area (host points) where the pointer reveals the buttons in full screen.
    private var buttonRevealArea: CGRect? {
        guard let controls else { return nil }
        let rects = [controls.close, controls.minimize, controls.zoom, controls.fullScreen].compactMap { $0 }
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -16, dy: -12)
    }

    /// Full screen hides the buttons like a full-screen app's title bar: any
    /// view over the video there makes the window server composite every
    /// frame (see docs/performance.md), so they only appear while needed.
    private func revealButtonsInFullScreen(near point: CGPoint) {
        let reveal = buttonRevealArea?.contains(point) ?? false
        guard reveal != revealsButtonsInFullScreen else { return }
        revealsButtonsInFullScreen = reveal
        layoutWindowButtons()
    }

    private func windowButtonsExited() {
        guard isFullScreen else { return }
        revealButtonsInFullScreen(near: hostPoint(forScreenPoint: NSEvent.mouseLocation))
    }

    @objc private func closeHostWindow(_ sender: Any?) {
        perform(.close, option: false)
    }

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

    /// The host app minimized (the host has already undone it on its side),
    /// or its window went in or out of full screen, which this window follows.
    func applyHostStateRequest(_ request: HostWindowStateRequest) {
        guard let window else { return }
        switch request {
        case .minimize:
            if !window.isMiniaturized { window.miniaturize(nil) }
        case .enterFullScreen:
            hostFullScreen = true
            enteredForHost = true
            if !isFullScreen, !inFullScreenTransition { window.toggleFullScreen(nil) }
        case .exitFullScreen:
            hostFullScreen = false
            if isFullScreen, !inFullScreenTransition { window.toggleFullScreen(nil) }
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

    func toggleStatistics() {
        showsStatistics.toggle()
        if !showsStatistics { surface.frameLayer.overlayText = nil }
    }

    private func updateStatistics() {
        let summary = stats.drain()
        let backing = window?.backingScaleFactor ?? 0
        let viewPixels = surface.convertToBacking(surface.bounds).size
        let native = Int(viewPixels.width) == summary.pixelSize.width && Int(viewPixels.height) == summary.pixelSize.height
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
        if showsStatistics, let audio = connection.audioReport { lines.append(audio.description) }
        lines.append("""
        host \(Int(remotePointSize.width))×\(Int(remotePointSize.height))pt @\(remoteScale)x · \
        local \(Int(viewPixels.width))×\(Int(viewPixels.height))px @\(Int(backing))x · \
        \(native ? "1:1 native" : "scaled") · rtt \(rtt)
        """)
        if let content = window?.contentView {
            connectionStatus.update(viewer: summary, host: hostReport, roundTrip: connection.client.roundTripMilliseconds,
                                    in: content)
        }
        let text = lines.joined(separator: "\n")
        if showsStatistics { surface.frameLayer.overlayText = text }
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
        layoutWindowButtons()
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
        layoutWindowButtons()
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
    // A host window in full screen of its own already has its screen's size;
    // the picture fits this screen however the two differ.
    func windowWillEnterFullScreen(_ notification: Notification) {
        inFullScreenTransition = true
        layoutWindowButtons()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        inFullScreenTransition = true
        layoutWindowButtons()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        inFullScreenTransition = false
        revealsButtonsInFullScreen = false
        updateVideoGravity()
        layoutWindowButtons()
        // The host window left full screen while this one was going in.
        if !hostFullScreen, enteredForHost { window?.toggleFullScreen(nil); return }
        if !hostFullScreen { requestHostResize(surface.bounds.size) }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        inFullScreenTransition = false
        enteredForHost = false
        updateVideoGravity()
        layoutWindowButtons()
        if hostFullScreen {
            // Left here (green button, ⌃⌘F): the host window leaves too, and
            // then takes this window's size again.
            hostFullScreen = false
            connection.client.send(.windowAction(streamID: streamID, action: .exitFullScreen))
        }
        requestHostResize(surface.bounds.size)
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        inFullScreenTransition = false
        layoutWindowButtons()
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        inFullScreenTransition = false
        layoutWindowButtons()
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
        NotificationCenter.default.post(name: .mirrorsChanged, object: nil)
    }
}

/// A titled window whose title bar chrome is hidden and passes clicks
/// through, so the host window's own title bar and toolbar receive them.
/// Its close, minimize and zoom buttons live on in a `WindowButtonGroup`
/// over the host window's buttons.
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
