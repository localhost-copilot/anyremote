import AnyRemoteMedia
import AnyRemoteNetwork
import AnyRemoteWindowControl
import AnyRemoteWire
import Foundation
import OSLog
@preconcurrency import ScreenCaptureKit

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "HostSession")

/// One streamed host surface: an opened window or one of its child windows.
final class HostStream: @unchecked Sendable {
    var description: StreamDescription
    let sender: WindowStreamSender
    let pid: pid_t
    var axWindow: AXWindow?
    /// Main windows: child window ID → child stream ID.
    var children: [CGWindowID: UInt16] = [:]
    /// Where the window was before it was moved onto the virtual display.
    var originalOrigin: CGPoint?
    var bitRate: Int
    var cleanReports = 0
    var controls: WindowControls?
    /// The window frame when the current press began.
    var pressFrame: CGRect?

    init(description: StreamDescription, sender: WindowStreamSender, pid: pid_t, bitRate: Int) {
        self.description = description
        self.sender = sender
        self.pid = pid
        self.bitRate = bitRate
    }

    var streamID: UInt16 { description.streamID }
    var windowID: CGWindowID { description.windowID }
}

/// Host side of one connected viewer.
///
/// All session state, Accessibility calls and event posting run on `queue`,
/// in arrival order, so a focus change always lands before the click that
/// needed it. Video leaves through `send(datagrams:)` from encoder queues.
final class HostSession: @unchecked Sendable {
    static let minimumBitRate = 6_000_000
    static let maximumBitRate = 80_000_000
    static let initialBitRate = 40_000_000
    static let maximumChildren = 12

    let sessionID: UInt32
    let queue: DispatchQueue
    let connection: ControlConnection
    private weak var service: HostService?
    private(set) var viewerName = ""
    private var authenticated = false

    private let datagramLock = NSLock()
    private var datagramOpener: DatagramOpener?
    private var datagramSealer: DatagramSealer?
    private var peerAddress: SocketAddress?

    // Queue-confined.
    private var streams: [UInt16: HostStream] = [:]
    private var openingWindows: Set<CGWindowID> = []
    private var nextStreamID: UInt16 = 1
    private let injector = InputInjector()
    private var tracker: DispatchSourceTimer?
    private var trackerFast = false
    private var reportTimer: DispatchSourceTimer?
    private var cursor: CursorMonitor?
    private var pendingResizes: [UInt16: CGSize] = [:]
    private var standardWindowCache: [pid_t: (ids: Set<CGWindowID>, time: UInt64)] = [:]
    private var lastFocusCheck: UInt64 = 0
    private var lastStateCheck: UInt64 = 0
    /// Layer-0 windows on screen at the last tracking pass; nil until the first stream.
    private var knownWindows: Set<CGWindowID>?
    private var lastInputTime: UInt64 = 0
    /// New windows that may still turn out to be standard windows, by first sighting.
    private var newWindowCandidates: [CGWindowID: UInt64] = [:]
    private var lastCandidateCheck: UInt64 = 0
    private var ended = false
    private let menuQueue = DispatchQueue(label: "anyremote.menu", qos: .userInitiated)

    init(sessionID: UInt32, connection: ControlConnection, queue: DispatchQueue, service: HostService) {
        self.sessionID = sessionID
        self.connection = connection
        self.queue = queue
        self.service = service
    }

    // MARK: Lifecycle

    func secured(_ info: SecureSessionInfo) {
        datagramLock.lock()
        datagramOpener = DatagramOpener(key: info.keys.datagramViewerToHost, sessionID: sessionID)
        datagramSealer = DatagramSealer(key: info.keys.datagramHostToViewer, sessionID: sessionID)
        datagramLock.unlock()
    }

    func handle(_ message: ControlMessage) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !ended else { return }
        if !authenticated {
            guard case let .authenticate(viewerName, takeOver) = message else {
                connection.close(after: .rejected(reason: "Expected authentication."))
                return
            }
            self.viewerName = viewerName
            guard let service, service.admit(self, takeOver: takeOver) else {
                let holder = self.service?.activeViewerName ?? "another viewer"
                connection.close(after: .rejected(reason: "This Mac is being controlled by \(holder)."))
                return
            }
            authenticated = true
            log.notice("viewer \(viewerName, privacy: .public) connected")
            sendWelcome()
            startTimers()
            return
        }

        switch message {
        case let .ping(id, viewerTime):
            connection.send(.pong(id: id, viewerTime: viewerTime, hostTime: HostClock.nowNanos()))
        case let .listWindows(requestID, thumbnailMaxPixels):
            listWindows(requestID: requestID, thumbnailMaxPixels: thumbnailMaxPixels)
        case let .openWindow(windowID):
            openWindow(windowID)
        case let .closeStream(streamID):
            endStream(streamID, reason: "Closed by viewer.", notify: false)
        case let .requestKeyframe(streamID):
            streams[streamID]?.sender.requestKeyframe()
        case let .receiverReport(streamID, received, dropped):
            adaptBitRate(streamID: streamID, received: received, dropped: dropped)
        case let .resize(streamID, size):
            scheduleResize(streamID: streamID, size: size)
        case let .focus(streamID):
            if let stream = streams[streamID] { focus(stream, force: true) }
        case let .input(streamID, event):
            inject(event, streamID: streamID)
        case let .requestMenuBar(streamID):
            readMenuBar(streamID: streamID)
        case let .performMenuItem(streamID, path):
            performMenuItem(streamID: streamID, path: path)
        case let .windowAction(streamID, action):
            perform(action, streamID: streamID)
        case .goodbye:
            end(reason: "Viewer disconnected.")
        default:
            log.debug("unexpected message from viewer")
        }
    }

    /// Stops every stream and restores moved windows. Idempotent.
    func end(reason: String, notifyViewer: Bool = false) {
        queue.async { [self] in
            guard !ended else { return }
            ended = true
            tracker?.cancel()
            reportTimer?.cancel()
            cursor?.stop()
            if injector.isPressed { injector.releaseAll(windowOrigin: .zero) }
            for id in Array(streams.keys) { endStream(id, reason: reason, notify: false) }
            if notifyViewer {
                connection.close(after: .goodbye(reason: reason))
            } else {
                connection.close()
            }
            service?.sessionEnded(self)
            log.notice("session ended: \(reason, privacy: .public)")
        }
    }

    static func missingPermissions() -> [String] {
        var missing: [String] = []
        if !CGPreflightScreenCaptureAccess() { missing.append("screen-recording") }
        if !AccessibilityPermission.isGranted { missing.append("accessibility") }
        if !InputInjector.isAllowed { missing.append("post-events") }
        return missing
    }

    private func sendWelcome() {
        let service = service
        Task { @MainActor in
            let displays = HostWindows.displays(virtualDisplayIDs: service?.virtualDisplayIDs ?? [])
            let missing = Self.missingPermissions()
            let welcome = HostWelcome(hostID: service?.settings.hostID ?? "", hostName: ComputerName.current,
                                      datagramPort: service?.datagramPort ?? 0, displays: displays,
                                      missingPermissions: missing)
            self.connection.send(.welcome(welcome))
        }
    }

    private func startTimers() {
        let tracker = DispatchSource.makeTimerSource(queue: queue)
        tracker.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(5))
        tracker.setEventHandler { [weak self] in self?.track() }
        tracker.resume()
        self.tracker = tracker

        let reportTimer = DispatchSource.makeTimerSource(queue: queue)
        reportTimer.schedule(deadline: .now() + 1, repeating: .seconds(1))
        reportTimer.setEventHandler { [weak self] in self?.sendReports() }
        reportTimer.resume()
        self.reportTimer = reportTimer
    }

    private func setTrackerFast(_ fast: Bool) {
        guard fast != trackerFast else { return }
        trackerFast = fast
        tracker?.schedule(deadline: .now(), repeating: .milliseconds(fast ? 8 : 33), leeway: .milliseconds(2))
    }

    // MARK: Datagrams

    /// Called on the service's socket queue.
    func handleDatagram(_ datagram: Data, from address: SocketAddress) {
        datagramLock.lock()
        guard var opener = datagramOpener, let plaintext = try? opener.open(datagram) else {
            datagramLock.unlock()
            return
        }
        datagramOpener = opener
        let isNewPeer = peerAddress != address
        if plaintext == DatagramKind.keepaliveDatagram { peerAddress = address }
        datagramLock.unlock()
        if isNewPeer {
            log.info("viewer datagrams from \(address.description, privacy: .public)")
            queue.async { [self] in streams.values.forEach { $0.sender.requestKeyframe() } }
        }
    }

    /// Thread-safe.
    private func send(datagrams: [Data]) {
        datagramLock.lock()
        let peer = peerAddress
        let sealer = datagramSealer
        datagramLock.unlock()
        guard let peer, let sealer, let socket = service?.socket else { return }
        for datagram in datagrams {
            guard let sealed = try? sealer.seal(datagram) else { continue }
            socket.send(sealed, to: peer)
        }
    }

    // MARK: Window library

    private func listWindows(requestID: UInt32, thumbnailMaxPixels: Int) {
        let service = service
        let connection = connection
        Task {
            do {
                let pairs = try await HostWindows.shareable(excludingPID: ProcessInfo.processInfo.processIdentifier,
                                                            includeOwnWindowIDs: service?.includedOwnWindowIDs ?? [])
                let summaries = pairs.map(\.1)
                let thumbnails = await HostWindows.thumbnails(for: pairs.map(\.0),
                                                              maximumPixels: min(thumbnailMaxPixels, 1024))
                let (displays, icons) = await MainActor.run {
                    (HostWindows.displays(virtualDisplayIDs: service?.virtualDisplayIDs ?? []),
                     service?.icons(for: summaries) ?? [:])
                }
                connection.send(.windowList(requestID: requestID, windows: summaries, displays: displays,
                                            thumbnails: thumbnails, icons: icons,
                                            missingPermissions: Self.missingPermissions()))
            } catch {
                log.error("window list failed: \(error.localizedDescription, privacy: .public)")
                connection.send(.windowList(requestID: requestID, windows: [], displays: [], thumbnails: [:],
                                            icons: [:], missingPermissions: Self.missingPermissions()))
            }
        }
    }

    // MARK: Streams

    private func openWindow(_ windowID: CGWindowID) {
        if let existing = streams.values.first(where: { $0.windowID == windowID && $0.description.role == .window }) {
            connection.send(.streamStarted(existing.description))
            existing.sender.requestKeyframe()
            return
        }
        guard !openingWindows.contains(windowID) else { return }
        openingWindows.insert(windowID)
        Task { [self] in
            let window = try? await HostWindows.scWindow(id: windowID)
            queue.async { [self] in
                openingWindows.remove(windowID)
                guard !ended else { return }
                guard let window, let app = window.owningApplication else {
                    connection.send(.streamEnded(streamID: 0, reason: "The window is no longer available."))
                    return
                }
                let summary = HostWindows.summary(window, app: app)
                startStream(window: window, pid: app.processID, role: .window, parent: nil, layer: 0,
                            title: summary.title, applicationName: summary.applicationName)
            }
        }
    }

    private func allocateStreamID() -> UInt16 {
        repeat {
            nextStreamID = nextStreamID == UInt16.max ? 1 : nextStreamID + 1
        } while streams[nextStreamID] != nil
        return nextStreamID
    }

    private func startStream(window: SCWindow, pid: pid_t, role: StreamDescription.Role, parent: UInt16?,
                             layer: Int, title: String, applicationName: String) {
        let streamID = allocateStreamID()
        let description = StreamDescription(streamID: streamID, windowID: window.windowID, role: role,
                                            parentStreamID: parent, frame: window.frame, layer: layer,
                                            title: title, applicationName: applicationName)
        let configuration = HEVCEncoder.Configuration(averageBitRate: role == .window ? Self.initialBitRate : 12_000_000,
                                                      alpha: role == .child)
        let sender = WindowStreamSender(
            window: window, streamID: streamID, configuration: configuration,
            maximumDatagramSize: 1400 - DatagramEnvelope.overhead
        ) { [weak self] datagrams in
            self?.send(datagrams: datagrams)
        }
        let stream = HostStream(description: description, sender: sender, pid: pid,
                                bitRate: configuration.averageBitRate)
        stream.axWindow = role == .window ? try? AXWindow(pid: pid, windowID: window.windowID) : nil
        streams[streamID] = stream
        if let parent { streams[parent]?.children[window.windowID] = streamID }
        sender.onStop = { [weak self] error in
            self?.queue.async {
                self?.endStream(streamID, reason: error == nil ? "Capture stopped." : "The window was closed.")
            }
        }
        if role == .window { prepareForStreaming(stream) }
        connection.send(.streamStarted(stream.description))
        if role == .window { sendControls(stream) }
        if cursor == nil {
            let connection = connection
            let monitor = CursorMonitor { image in connection.send(.cursor(image)) }
            monitor.start()
            cursor = monitor
        }
        Task {
            do {
                try await sender.start()
            } catch {
                log.error("capture start failed: \(error.localizedDescription, privacy: .public)")
                queue.async { [self] in
                    endStream(streamID, reason: "Capture failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Moves the window onto the HiDPI virtual display when one is in use.
    private func prepareForStreaming(_ stream: HostStream) {
        guard let service, let target = service.virtualDisplayFrameForNewStream(),
              let ax = stream.axWindow, let origin = ax.position else { return }
        guard !target.contains(CGPoint(x: origin.x + 1, y: origin.y + 1)) else { return }
        stream.originalOrigin = origin
        try? ax.setPosition(CGPoint(x: target.minX, y: target.minY))
        if let size = ax.size, size.width > target.width || size.height > target.height {
            try? ax.setSize(CGSize(width: min(size.width, target.width), height: min(size.height, target.height)))
        }
    }

    private func endStream(_ streamID: UInt16, reason: String, notify: Bool = true) {
        guard let stream = streams.removeValue(forKey: streamID) else { return }
        for child in stream.children.values { endStream(child, reason: reason, notify: notify) }
        if let parent = stream.description.parentStreamID {
            streams[parent]?.children.removeValue(forKey: stream.windowID)
        }
        if let origin = stream.originalOrigin { try? stream.axWindow?.setPosition(origin) }
        let sender = stream.sender
        Task { await sender.stop() }
        if notify { connection.send(.streamEnded(streamID: streamID, reason: reason)) }
        if !streams.values.contains(where: { $0.description.role == .window }) {
            cursor?.stop()
            cursor = nil
            service?.streamsDidEnd(session: self)
        }
    }

    private func adaptBitRate(streamID: UInt16, received: UInt32, dropped: UInt32) {
        guard let stream = streams[streamID] else { return }
        let ceiling = stream.description.role == .window ? Self.maximumBitRate : 20_000_000
        var bitRate = stream.bitRate
        if dropped > 0 {
            bitRate = max(Self.minimumBitRate, bitRate * 3 / 4)
            stream.cleanReports = 0
        } else if received > 0 {
            stream.cleanReports += 1
            if stream.cleanReports >= 4 {
                bitRate = min(ceiling, bitRate + bitRate / 10)
                stream.cleanReports = 0
            }
        }
        if bitRate != stream.bitRate {
            stream.bitRate = bitRate
            stream.sender.setAverageBitRate(bitRate)
        }
    }

    private func sendReports() {
        for stream in streams.values {
            let summary = stream.sender.stats.drain()
            guard summary.framesPerSecond > 0 else { continue }
            connection.send(.hostReport(streamID: stream.streamID, HostStreamReport(
                captureP50: summary.p50[.capture] ?? 0, waitP50: summary.p50[.encodeWait] ?? 0,
                encodeP50: summary.p50[.encode] ?? 0, encodeP95: summary.p95[.encode] ?? 0,
                framesPerSecond: summary.framesPerSecond, megabitsPerSecond: summary.megabitsPerSecond,
                bitRate: stream.bitRate)))
        }
    }

    // MARK: Tracking (moves, titles, child windows)

    private func track() {
        let mains = streams.values.filter { $0.description.role == .window }
        guard !mains.isEmpty else { return }
        checkWindowStates(mains)
        let onScreen = WindowServerWindow.onScreen()
        var byID: [CGWindowID: WindowServerWindow] = [:]
        for window in onScreen { byID[window.id] = window }
        openNewWindows(onScreen)

        for main in mains {
            guard let current = byID[main.windowID] else { continue }
            updateFrame(main, frame: current.frame, title: current.title)
            trackChildren(of: main, mainFrame: current.frame, onScreen: onScreen)
        }
        for stream in streams.values where stream.description.role == .child {
            if let current = byID[stream.windowID] { updateFrame(stream, frame: current.frame, title: current.title) }
        }
    }

    private func updateFrame(_ stream: HostStream, frame: CGRect, title: String) {
        let title = title.isEmpty ? stream.description.title : title
        guard frame.origin != stream.description.frame.origin || frame.size != stream.description.frame.size
            || title != stream.description.title else { return }
        let resized = frame.size != stream.description.frame.size
        stream.description.frame = frame
        if resized, stream.description.role == .window { sendControls(stream) }
        stream.description.title = title
        connection.send(.streamMoved(streamID: stream.streamID, frame: frame, title: title))
    }

    // MARK: Title bar buttons and window state

    /// Tells the viewer where the title bar buttons are, so it can handle
    /// minimize and full screen on its own window.
    private func sendControls(_ stream: HostStream) {
        if stream.axWindow == nil { stream.axWindow = try? AXWindow(pid: stream.pid, windowID: stream.windowID) }
        guard let frames = stream.axWindow?.controlFrames else { return }
        let controls = WindowControls(close: frames.close, minimize: frames.minimize, zoom: frames.zoom,
                                      fullScreen: frames.fullScreen)
        guard controls != stream.controls else { return }
        stream.controls = controls
        connection.send(.windowControls(streamID: stream.streamID, controls))
    }

    private func perform(_ action: WindowAction, streamID: UInt16) {
        guard let stream = streams[streamID], stream.description.role == .window else { return }
        if stream.axWindow == nil { stream.axWindow = try? AXWindow(pid: stream.pid, windowID: stream.windowID) }
        switch action {
        case .close:
            if stream.axWindow?.pressCloseButton() != true { log.notice("close button press failed") }
        }
    }

    /// A streamed window that got minimized or went full screen on the host
    /// (Window › Minimize, ⌘M, ⌃⌘F, a title bar double-click) is put back and
    /// the viewer does it to its local window instead.
    private func checkWindowStates(_ mains: [HostStream]) {
        let now = HostClock.nowNanos()
        guard now - lastStateCheck >= 150_000_000 else { return }
        lastStateCheck = now
        for stream in mains {
            guard let window = stream.axWindow else { continue }
            if window.isMinimized {
                window.setMinimized(false)
                connection.send(.windowStateRequest(streamID: stream.streamID, .minimize))
            } else if window.isFullScreen {
                window.setFullScreen(false)
                connection.send(.windowStateRequest(streamID: stream.streamID, .enterFullScreen))
            }
        }
    }

    /// A window that appears right after the viewer clicked or typed is one
    /// the viewer caused: a new document, a preferences window, or another
    /// app's window such as Finder revealing a file. It opens on the viewer
    /// like a window picked from the list. Windows that show up on their own
    /// stay on the host.
    private func openNewWindows(_ onScreen: [WindowServerWindow]) {
        let ownPID = getpid()
        let now = HostClock.nowNanos()
        let current = Set(onScreen.lazy.filter { $0.layer == 0 && $0.pid != ownPID }.map(\.id))
        if let known = knownWindows, now - lastInputTime < Self.causedWindowInterval {
            for id in current.subtracting(known) { newWindowCandidates[id] = now }
        }
        knownWindows = current
        guard !newWindowCandidates.isEmpty, now - lastCandidateCheck >= 100_000_000 else { return }
        lastCandidateCheck = now
        let streamed = Set(streams.values.map(\.windowID))
        // A new window is often listed before it has its final size and
        // before Accessibility knows it, so look again for a moment.
        for window in onScreen {
            guard let seen = newWindowCandidates[window.id] else { continue }
            if streamed.contains(window.id) || now - seen > 1_500_000_000 {
                newWindowCandidates[window.id] = nil
                continue
            }
            guard window.frame.width >= 160, window.frame.height >= 100, window.alpha > 0.01,
                  !Self.panelServiceNames.contains(where: { window.ownerName.contains($0) }),
                  AXWindow.standardWindowIDs(pid: window.pid).contains(window.id) else { continue }
            newWindowCandidates[window.id] = nil
            log.notice("opening new window \(window.id) of \(window.ownerName, privacy: .public)")
            openWindow(window.id)
        }
        newWindowCandidates = newWindowCandidates.filter { current.contains($0.key) }
    }

    private static let causedWindowInterval: UInt64 = 3_000_000_000

    private static let panelServiceNames = ["OpenAndSavePanelService", "Open and Save Panel Service"]

    private func trackChildren(of main: HostStream, mainFrame: CGRect, onScreen: [WindowServerWindow]) {
        let near = mainFrame.insetBy(dx: -400, dy: -400)
        var candidates: [WindowServerWindow] = []
        var needsStandardIDs = false
        // Mirroring one of our own windows: our mirrors and child panels are
        // same-PID windows too, and capturing them would feed back.
        let ownAllowed = main.pid == getpid() ? service?.includedOwnWindowIDs ?? [] : nil
        for window in onScreen where window.id != main.windowID && window.alpha > 0.01 {
            if let ownAllowed, window.pid == main.pid, window.layer == 0, !ownAllowed.contains(window.id) { continue }
            guard window.frame.width >= 4, window.frame.height >= 4 else { continue }
            let samePID = window.pid == main.pid
            let panelService = !samePID && Self.panelServiceNames.contains { window.ownerName.contains($0) }
            guard samePID || panelService else { continue }
            if window.layer == 0 {
                // Tiny layer-0 helpers (the text input source indicator, ...)
                // are not part of the window's UI.
                guard window.frame.intersects(near), window.frame.width >= 80, window.frame.height >= 30 else { continue }
                if samePID { needsStandardIDs = true }
                candidates.append(window)
            } else if window.layer > 0, window.layer < 1000, window.layer != 24, window.layer != 25 {
                candidates.append(window)
            }
        }
        if needsStandardIDs {
            let standard = standardWindowIDs(pid: main.pid)
            candidates.removeAll { $0.layer == 0 && $0.pid == main.pid && standard.contains($0.id) }
        }
        let wanted = Set(candidates.prefix(Self.maximumChildren).map(\.id))

        for (windowID, streamID) in main.children where !wanted.contains(windowID) {
            endStream(streamID, reason: "Child window closed.")
        }
        let missing = candidates.prefix(Self.maximumChildren).filter { main.children[$0.id] == nil }
        guard !missing.isEmpty else { return }
        for window in missing { main.children[window.id] = 0 } // reserved while SCK looks it up
        let mainID = main.streamID
        Task { [self] in
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            queue.async { [self] in
                guard let parent = streams[mainID] else { return }
                for window in missing {
                    parent.children.removeValue(forKey: window.id)
                    guard let scWindow = content?.windows.first(where: { $0.windowID == window.id }) else { continue }
                    startStream(window: scWindow, pid: window.pid, role: .child, parent: mainID, layer: window.layer,
                                title: window.title, applicationName: window.ownerName)
                }
            }
        }
    }

    private func standardWindowIDs(pid: pid_t) -> Set<CGWindowID> {
        let now = HostClock.nowNanos()
        if let cached = standardWindowCache[pid], now - cached.time < 500_000_000 { return cached.ids }
        let ids = AXWindow.standardWindowIDs(pid: pid)
        standardWindowCache[pid] = (ids, now)
        return ids
    }

    // MARK: Input

    private func inject(_ event: InputEvent, streamID: UInt16) {
        guard let stream = streams[streamID], stream.description.role == .window else { return }
        var origin = stream.description.frame.origin
        switch event {
        case .mouseDown, .mouseUp, .key(_, true, _, _):
            lastInputTime = HostClock.nowNanos()
        default:
            break
        }
        switch event {
        case .mouseDown:
            focus(stream, force: false)
            if let current = WindowServerWindow.describe(stream.windowID) { origin = current.frame.origin }
            if !injector.isPressed { stream.pressFrame = stream.description.frame }
            setTrackerFast(true)
        case .key(_, true, _, _):
            focus(stream, force: false)
        default:
            break
        }
        injector.post(event, windowOrigin: origin)
        if case .mouseUp = event, !injector.isPressed {
            setTrackerFast(false)
            // Once the drag has ended, and again after macOS's own snap-back
            // (it keeps 40 pt of a window visible) has run.
            for (delay, final) in [(150, false), (600, true)] {
                queue.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
                    self?.keepInPlace(streamID: streamID, final: final)
                }
            }
        }
    }

    /// The host window never moves for the viewer: dragging a mirror by its
    /// title bar (or toolbar, or background) moves only the local window. The
    /// press reaches the host first, so the app starts a drag; the viewer
    /// notices the move, ends the press and drags locally, and the window is
    /// put back here. Left moved, it could end up partly off its display,
    /// where clicks go nowhere.
    private func keepInPlace(streamID: UInt16, final: Bool) {
        guard let stream = streams[streamID], !injector.isPressed, let pressFrame = stream.pressFrame else { return }
        if final { stream.pressFrame = nil }
        if stream.axWindow == nil { stream.axWindow = try? AXWindow(pid: stream.pid, windowID: stream.windowID) }
        // A resize from the left or top edge moves the origin too; that stays.
        guard let ax = stream.axWindow, let origin = ax.position, let size = ax.size,
              size == pressFrame.size, origin != pressFrame.origin else { return }
        log.notice("window \(stream.windowID) moved back: \(origin.debugDescription) -> \(pressFrame.origin.debugDescription)")
        try? ax.setPosition(pressFrame.origin)
    }

    /// Brings the window's app forward when another window is frontmost.
    private func focus(_ stream: HostStream, force: Bool) {
        let now = HostClock.nowNanos()
        if !force, now - lastFocusCheck < 300_000_000 { return }
        lastFocusCheck = now
        let front = WindowServerWindow.onScreen().first { $0.layer == 0 }
        guard force || front?.id != stream.windowID else { return }
        if stream.axWindow == nil { stream.axWindow = try? AXWindow(pid: stream.pid, windowID: stream.windowID) }
        stream.axWindow?.focus()
        if front?.id != stream.windowID { usleep(20_000) }
    }

    // MARK: Resize

    private func scheduleResize(streamID: UInt16, size: CGSize) {
        let alreadyScheduled = pendingResizes[streamID] != nil
        pendingResizes[streamID] = size
        guard !alreadyScheduled else { return }
        queue.async { [self] in
            guard let size = pendingResizes.removeValue(forKey: streamID) else { return }
            applyResize(streamID: streamID, size: size)
        }
    }

    private func applyResize(streamID: UInt16, size requested: CGSize) {
        guard let stream = streams[streamID] else { return }
        if stream.axWindow == nil { stream.axWindow = try? AXWindow(pid: stream.pid, windowID: stream.windowID) }
        guard let ax = stream.axWindow else {
            connection.send(.resizeApplied(streamID: streamID, size: stream.description.frame.size))
            return
        }
        var size = requested
        let origin = ax.position ?? stream.description.frame.origin
        if let display = service?.visibleFrame(containing: origin) {
            size.width = min(size.width, display.width)
            size.height = min(size.height, display.height)
            // Keep the whole window on its display so every point stays clickable.
            var target = origin
            if origin.x + size.width > display.maxX { target.x = max(display.minX, display.maxX - size.width) }
            if origin.y + size.height > display.maxY { target.y = max(display.minY, display.maxY - size.height) }
            if target != origin { try? ax.setPosition(target) }
        }
        do {
            try ax.setSize(size)
        } catch {
            log.error("AX resize failed: \(String(describing: error), privacy: .public)")
        }
        connection.send(.resizeApplied(streamID: streamID, size: ax.size ?? size))
    }

    // MARK: Menu bar

    private func readMenuBar(streamID: UInt16) {
        guard let stream = streams[streamID] else { return }
        let pid = stream.pid
        let name = stream.description.applicationName
        let connection = connection
        menuQueue.async {
            let menus = MenuBarReader.read(pid: pid) ?? []
            connection.send(.menuBar(streamID: streamID, applicationName: name, menus: menus))
        }
    }

    private func performMenuItem(streamID: UInt16, path: [Int]) {
        guard let stream = streams[streamID] else { return }
        lastInputTime = HostClock.nowNanos()
        focus(stream, force: true)
        let pid = stream.pid
        menuQueue.async {
            if !MenuBarReader.perform(pid: pid, path: path) {
                log.error("menu item \(path, privacy: .public) could not be pressed")
            }
        }
    }
}
