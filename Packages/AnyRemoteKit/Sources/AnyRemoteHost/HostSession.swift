import AnyRemoteMedia
import AnyRemoteNetwork
import AnyRemoteWindowControl
import AnyRemoteWire
import Foundation
import Network
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
    var controls: WindowControls?
    /// Where macOS's sharing indicator covers the title bar buttons (window
    /// points from the top-left corner), painted over before encoding.
    var concealedRect: CGRect?
    /// The window frame when the current press began.
    var pressFrame: CGRect?
    /// When the window left the screen (closed, hidden), while it stays off.
    var offScreenSince: UInt64?
    /// Main windows: minimized on the host, as Accessibility last answered.
    var minimizedOnHost = false
    /// Display streams: the display's backing scale.
    var displayScale: CGFloat = 0
    /// Display streams: the display captured now (a virtual display standing
    /// in for `windowID` under dynamic resolution).
    var captureDisplayID: CGDirectDisplayID = 0
    /// Dynamic resolution: the virtual display that replaced `windowID`.
    var standIn: VirtualDisplay?
    var switchingDisplay = false
    /// Display streams: every session watching, the one that opened it first.
    let audience: StreamAudience?
    /// Shared streams: each viewer's own adaptation; the stream runs at the lowest.
    var viewerBitRates: [UInt32: (bitRate: Int, cleanReports: Int)] = [:]
    /// Shared streams: each viewer's dynamic-resolution request (nil: off);
    /// the first viewer's is applied.
    var desktopSizes: [UInt32: CGSize?] = [:]
    /// Shared streams: the first viewer drains the statistics, the others read this.
    var lastSummary: PipelineStats.Summary?

    init(description: StreamDescription, sender: WindowStreamSender, pid: pid_t, bitRate: Int,
         audience: StreamAudience? = nil) {
        self.description = description
        self.sender = sender
        self.pid = pid
        self.bitRate = bitRate
        self.audience = audience
    }

    var streamID: UInt16 { description.streamID }
    var windowID: CGWindowID { description.windowID }
}

/// The sessions watching one stream. A display is captured and encoded once
/// however many viewers watch it (the media engine has room for one 4K
/// desktop at full rate, not two); each viewer gets the same datagrams sealed
/// with its own session key. The first viewer leads: its window size sets
/// the dynamic resolution, and it follows the display's changes for all.
final class StreamAudience: @unchecked Sendable {
    private struct Member { weak var session: HostSession? }
    private let lock = NSLock()
    private var members: [Member] = []

    var sessions: [HostSession] {
        lock.lock()
        defer { lock.unlock() }
        return members.compactMap(\.session)
    }

    var leader: HostSession? { sessions.first }

    func add(_ session: HostSession) {
        lock.lock()
        members.removeAll { $0.session == nil || $0.session === session }
        members.append(Member(session: session))
        lock.unlock()
    }

    func remove(_ session: HostSession) {
        lock.lock()
        members.removeAll { $0.session == nil || $0.session === session }
        lock.unlock()
    }

    /// Thread-safe (encoder queues).
    func send(_ datagrams: [Data]) {
        for session in sessions { session.send(datagrams: datagrams) }
    }
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
    /// A whole desktop has many more pixels than a window, so it gets more room.
    static let displayInitialBitRate = 50_000_000
    static let displayMaximumBitRate = 120_000_000
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
    private var noDatagramsReports = 0

    // Queue-confined.
    private var streams: [UInt16: HostStream] = [:]
    private var openingWindows: Set<CGWindowID> = []
    private var nextStreamID: UInt16 = 1
    /// Further strips of display streams → the display stream.
    private var tileOwners: [UInt16: UInt16] = [:]
    /// Display streams go out as this many strips (`ANYREMOTE_TILES`, 1 for whole frames).
    static let displayTiles = max(1, min(8, Int(ProcessInfo.processInfo.environment["ANYREMOTE_TILES"] ?? "") ?? 4))
    private let injector = InputInjector()
    private var tracker: DispatchSourceTimer?
    private var trackerFast = false
    private var reportTimer: DispatchSourceTimer?
    private var cursor: CursorMonitor?
    private var pendingResizes: [UInt16: CGSize] = [:]
    /// Apps' standard window IDs as last answered, and when that was asked.
    private var standardWindowCache: [pid_t: (ids: Set<CGWindowID>?, asked: UInt64)] = [:]
    /// Accessibility queries the tracking polls for; none runs on `queue`.
    private let poller = AccessibilityPoller()
    private var lastFocusCheck: UInt64 = 0
    private var lastStateCheck: UInt64 = 0
    /// Layer-0 windows on screen at the last tracking pass; nil until the first stream.
    private var knownWindows: Set<CGWindowID>?
    private var lastInputTime: UInt64 = 0
    /// When the viewer last clicked or typed. Queue-confined.
    var lastInputNanos: UInt64 { lastInputTime }
    /// New windows that may still turn out to be standard windows, by first sighting.
    private var newWindowCandidates: [CGWindowID: UInt64] = [:]
    private var lastCandidateCheck: UInt64 = 0
    /// An app the viewer asked to open; its first window opens on the viewer.
    private var pendingLaunch: (path: String, pid: pid_t?, deadline: UInt64)?
    private var ended = false
    /// The viewer wants the sound of what it shows.
    private var audioRequested = false
    private var audio: (scope: AudioScope, tap: ProcessAudioTap)?
    private let menuQueue = DispatchQueue(label: "anyremote.menu", qos: .userInitiated)
    private let caretQueue = DispatchQueue(label: "anyremote.caret", qos: .userInitiated)
    private let caretLocator = CaretLocator()
    /// A caret lookup is scheduled or running; typing doesn't queue one per key.
    private var caretLookupPending = false
    /// Input arrived while a lookup was pending: look again once it's done.
    private var caretLookupStale = false
    /// When the last input that may move the caret arrived.
    private var lastCaretInput: UInt64 = 0
    /// The caret last sent, per stream.
    private var sentCarets: [UInt16: CaretState] = [:]
    /// Small same-app windows (Finder's rename field) and whether they hold
    /// the focused text field, with when that was last checked.
    private var textEditorWindows: [CGWindowID: (holdsFocus: Bool, checked: UInt64)] = [:]
    /// The stream that last got a key or click: the one whose caret matters.
    private var lastInputStreamID: UInt16?
    /// Whose input method composes; the viewer says once connected.
    private var textInput = TextInputSettings(composesOnViewer: true)
    /// Processes and whether they are input methods (their candidate windows
    /// belong with the window being typed into).
    private var inputMethodProcesses: [pid_t: InputMethodProcess] = [:]

    /// The viewer's transfer connection presents this to join the session.
    private var transferToken: Data?
    private var transfer: FileTransferChannel?
    private lazy var dragBridge: HostDragBridge = {
        let connection = connection
        let bridge = HostDragBridge(queue: queue, injector: injector) { connection.send($0) }
        bridge.streamOrigin = { [unowned self] streamID in surfaceOrigin(streamID) }
        bridge.raiseStream = { [unowned self] streamID in
            if let stream = streams[streamID], stream.description.role == .window { focus(stream, force: true) }
        }
        return bridge
    }()

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
            if case let .transfer(.attach(sessionID, token)) = message {
                // Not a viewer: another session's transfer connection.
                ended = true
                service?.attachTransfer(connection, from: self, toSession: sessionID, token: token)
                return
            }
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
        case let .openDisplay(displayID):
            openDisplay(displayID)
        case let .desktopSize(streamID, size):
            scheduleDesktopSize(streamID: streamID, size: size)
        case let .listApplications(requestID):
            listApplications(requestID: requestID)
        case let .launchApplication(path):
            launchApplication(path)
        case let .quitApplication(path, force):
            quitApplication(path, force: force)
        case let .peerPairing(pairing):
            receivePeerPairing(pairing)
        case let .pasteboardSharing(enabled):
            setPasteboardSharing(enabled)
        case let .pasteboard(items):
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated { pasteboardBridge?.apply(items) }
            }
        case let .closeStream(streamID):
            endStream(streamID, reason: "Closed by viewer.", notify: false)
        case let .requestKeyframe(streamID):
            // A strip's receiver asks for that strip only.
            streams[tileOwners[streamID] ?? streamID]?.sender.requestKeyframe(streamID: streamID)
        case let .receiverReport(streamID, received, dropped):
            if let owner = tileOwners[streamID] {
                // Strips: the first one's reports pace the stream; loss in any backs it off.
                if dropped > 0 { adaptBitRate(streamID: owner, received: 0, dropped: dropped) }
            } else {
                adaptBitRate(streamID: streamID, received: received, dropped: dropped)
            }
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
        case let .audio(enabled):
            audioRequested = enabled
            updateAudio()
        case let .textInput(settings):
            applyTextInput(settings)
        case let .microphone(enabled):
            service?.microphone.setOffered(enabled, by: self)
        case let .microphoneStream(format):
            service?.microphone.streamChanged(format, from: self)
        case .transferToken(let token):
            transferToken = token
        case .drag(let event):
            dragBridge.handle(event)
        case .goodbye:
            end(reason: "Viewer disconnected.")
        default:
            log.debug("unexpected message from viewer")
        }
    }

    /// Main-thread only.
    nonisolated(unsafe) private var pasteboardBridge: PasteboardBridge?
    /// Main-thread only.
    nonisolated(unsafe) private var keyboardLayout: HostKeyboardLayout?

    private func applyTextInput(_ settings: TextInputSettings) {
        textInput = settings
        log.notice("text input: \(settings.composesOnViewer ? "viewer composes" : "host composes", privacy: .public)")
        // The host's input method composes: give back what the viewer's mode had replaced.
        if !settings.composesOnViewer { restoreKeyboardLayout() }
    }

    private func ensureKeyboardLayout() {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                if keyboardLayout == nil { keyboardLayout = HostKeyboardLayout() }
                keyboardLayout?.ensureKeyboardLayout()
            }
        }
    }

    private func restoreKeyboardLayout() {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                keyboardLayout?.restore()
                keyboardLayout = nil
            }
        }
    }

    private func setPasteboardSharing(_ enabled: Bool) {
        let connection = connection
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                pasteboardBridge?.stop()
                pasteboardBridge = nil
                guard enabled else { return }
                // The viewer sends its clipboard when sharing starts; this side waits for a copy.
                let bridge = PasteboardBridge { items in connection.send(.pasteboard(items: items)) }
                bridge.start(sendingCurrent: false)
                pasteboardBridge = bridge
            }
        }
    }

    /// Stops every stream and restores moved windows. Idempotent.
    func end(reason: String, notifyViewer: Bool = false) {
        queue.async { [self] in
            guard !ended else { return }
            ended = true
            tracker?.cancel()
            reportTimer?.cancel()
            setPasteboardSharing(false)
            restoreKeyboardLayout()
            cursor?.stop()
            dragBridge.cancel()
            transfer?.close()
            transfer = nil
            if injector.isPressed { injector.releaseAll(windowOrigin: .zero) }
            for id in Array(streams.keys) { endStream(id, reason: reason, notify: false) }
            stopAudio()
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
        if plaintext.count >= 2, plaintext[plaintext.startIndex + 1] == DatagramKind.microphone {
            service?.microphone.receive(plaintext, from: sessionID)
            return
        }
        if isNewPeer {
            log.notice("viewer datagrams from \(address.description, privacy: .public)")
            queue.async { [self] in streams.values.forEach { $0.sender.requestKeyframe() } }
        }
    }

    /// Thread-safe.
    fileprivate func send(datagrams: [Data]) {
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

    // MARK: Applications

    private func listApplications(requestID: UInt32) {
        let service = service
        let connection = connection
        Task { @MainActor in
            let list = service?.applicationList() ?? (applications: [], icons: [:])
            connection.send(.applicationList(requestID: requestID, applications: list.applications, icons: list.icons))
        }
    }

    private func launchApplication(_ path: String) {
        let now = HostClock.nowNanos()
        pendingLaunch = (path, nil, now + 20_000_000_000)
        // Windows on screen now are not the app's new one.
        knownWindows = Self.trackedWindowIDs(WindowServerWindow.onScreen())
        log.notice("launching \(path, privacy: .public)")
        let url = URL(fileURLWithPath: path)
        Task { @MainActor [self] in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            let application = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            let pid = application?.processIdentifier
            queue.async { [self] in
                guard pendingLaunch?.path == path else { return }
                guard let pid else {
                    log.error("could not open \(path, privacy: .public)")
                    pendingLaunch = nil
                    return
                }
                pendingLaunch?.pid = pid
                // Already running: no new window may come; show its front one.
                queue.asyncAfter(deadline: .now() + 1) { [self] in openExistingWindow(pid: pid) }
            }
        }
    }

    private func quitApplication(_ path: String, force: Bool) {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        DispatchQueue.main.async {
            let running = NSWorkspace.shared.runningApplications.filter {
                $0.bundleURL?.standardizedFileURL == url && $0.processIdentifier != getpid()
            }
            log.notice("quitting \(path, privacy: .public) (\(running.count) running, force \(force))")
            for application in running {
                if force { application.forceTerminate() } else { application.terminate() }
            }
        }
    }

    private func receivePeerPairing(_ pairing: PeerPairing) {
        var address: String?
        if case let .hostPort(host, _) = connection.remoteEndpoint {
            switch host {
            case let .ipv4(ip): address = "\(ip)".components(separatedBy: "%").first
            case let .name(name, _): address = name
            // An IPv6 peer is reached over Bonjour.
            default: break
            }
        }
        if let port = pairing.port, port != 0, let host = address { address = "\(host):\(port)" } else { address = nil }
        log.notice("peer pairing from \(pairing.name, privacy: .public) at \(address ?? "Bonjour", privacy: .public): \(pairing.pairingCode == nil ? "withdrawn" : "offered", privacy: .public)")
        let callback = service?.onPeerPairing
        DispatchQueue.main.async { callback?(pairing, address) }
    }

    private func openExistingWindow(pid: pid_t) {
        guard pendingLaunch?.pid == pid else { return }
        let streamed = Set(streams.values.map(\.windowID))
        let standard = AXWindow.standardWindowIDs(pid: pid)
        // On-screen windows come front to back.
        guard let window = WindowServerWindow.onScreen().first(where: {
            $0.pid == pid && $0.layer == 0 && standard.contains($0.id) && !streamed.contains($0.id)
        }) else { return }
        pendingLaunch = nil
        openWindow(window.id)
    }

    private static func trackedWindowIDs(_ onScreen: [WindowServerWindow]) -> Set<CGWindowID> {
        let ownPID = getpid()
        return Set(onScreen.lazy.filter { $0.layer == 0 && $0.pid != ownPID }.map(\.id))
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

    /// Streams a whole display (full desktop).
    private func openDisplay(_ displayID: CGDirectDisplayID) {
        if let existing = streams.values.first(where: { $0.windowID == displayID && $0.description.role == .display }) {
            connection.send(.streamStarted(existing.description))
            existing.sender.requestKeyframe()
            return
        }
        // Another viewer is watching it already: share its stream.
        if let shared = service?.sessions(except: self).lazy.compactMap({ session in
            session.streams.values.first { $0.windowID == displayID && $0.description.role == .display }
        }).first, let audience = shared.audience {
            join(shared, audience: audience)
            return
        }
        guard let geometry = Self.displayGeometry(displayID) else {
            connection.send(.streamEnded(streamID: 0, reason: "The display is no longer available."))
            return
        }
        let streamID = allocateStreamID()
        var tileStreamIDs: [UInt16]?
        if Self.displayTiles > 1 {
            var ids = [streamID]
            // Reserve each before allocating the next.
            tileOwners[streamID] = streamID
            for _ in 1..<Self.displayTiles {
                let id = allocateStreamID()
                tileOwners[id] = streamID
                ids.append(id)
            }
            tileOwners[streamID] = nil
            tileStreamIDs = ids
        }
        let name = DispatchQueue.main.sync { MainActor.assumeIsolated { HostWindows.displayName(displayID) } } ?? "Display"
        let description = StreamDescription(streamID: streamID, windowID: displayID, role: .display,
                                            parentStreamID: nil, frame: geometry.frame, layer: 0,
                                            title: name, applicationName: ComputerName.current,
                                            tileStreamIDs: tileStreamIDs)
        let configuration = HEVCEncoder.Configuration(averageBitRate: Self.displayInitialBitRate)
        let audience = StreamAudience()
        audience.add(self)
        // Development: a viewer on this same Mac would see its own desktop
        // window inside itself, endlessly.
        let sender = WindowStreamSender(
            displayID: displayID, excludingProcessID: Self.isLoopback ? getpid() : nil,
            exceptingWindowIDs: service?.includedOwnWindowIDs ?? [], streamID: streamID,
            tileStreamIDs: tileStreamIDs, configuration: configuration,
            maximumDatagramSize: 1400 - DatagramEnvelope.overhead
        ) { [weak audience] datagrams in
            audience?.send(datagrams)
        }
        let stream = HostStream(description: description, sender: sender, pid: 0, bitRate: configuration.averageBitRate,
                                audience: audience)
        stream.displayScale = geometry.scale
        stream.captureDisplayID = displayID
        streams[streamID] = stream
        updateAudio()
        let queue = queue
        sender.onStop = { [weak audience] error in
            queue.async {
                let reason = error == nil ? "Capture stopped." : "The display is no longer available."
                for session in audience?.sessions ?? [] { session.endStream(streamID, reason: reason) }
            }
        }
        log.notice("streaming display \(displayID) \(geometry.frame.debugDescription, privacy: .public) @\(geometry.scale)x")
        connection.send(.streamStarted(description))
        startCursorMonitor()
        Task {
            do {
                try await sender.start()
            } catch {
                log.error("display capture start failed: \(error.localizedDescription, privacy: .public)")
                queue.async { [self] in
                    endStream(streamID, reason: "Capture failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Starts watching a display stream another session opened.
    private func join(_ stream: HostStream, audience: StreamAudience) {
        let streamID = stream.streamID
        if let tiles = stream.description.tileStreamIDs {
            for id in tiles where id != streamID { tileOwners[id] = streamID }
        }
        streams[streamID] = stream
        audience.add(self)
        updateAudio()
        log.notice("\(self.viewerName, privacy: .public) joins display \(stream.windowID) (\(audience.sessions.count) watching)")
        connection.send(.streamStarted(stream.description))
        stream.sender.requestKeyframe()
        startCursorMonitor()
    }

    /// Queue-confined.
    var isStreaming: Bool { !ended && !streams.isEmpty }

    static let isLoopback = ProcessInfo.processInfo.environment["ANYREMOTE_LOOPBACK"] == "1"

    /// A display's frame in global top-left points and its backing scale.
    static func displayGeometry(_ displayID: CGDirectDisplayID) -> (frame: CGRect, scale: CGFloat)? {
        guard CGDisplayIsOnline(displayID) != 0,
              let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        let frame = CGDisplayBounds(displayID)
        guard frame.width > 0, frame.height > 0 else { return nil }
        let scale = max(1, CGFloat(mode.pixelWidth) / CGFloat(max(1, mode.width)))
        return (frame, scale)
    }

    /// Follows display mode changes (resolution, scale, arrangement).
    private func trackDisplay(_ stream: HostStream) {
        guard !stream.switchingDisplay else { return }
        guard let geometry = Self.displayGeometry(stream.captureDisplayID) else {
            checkGone(stream)
            return
        }
        stream.offScreenSince = nil
        let frame = geometry.frame
        guard frame != stream.description.frame || geometry.scale != stream.displayScale else { return }
        if frame.size != stream.description.frame.size || geometry.scale != stream.displayScale {
            log.notice("display \(stream.windowID) changed to \(frame.size.debugDescription, privacy: .public) @\(geometry.scale)x")
            stream.sender.displayChanged(pointSize: frame.size, scale: geometry.scale)
        }
        stream.displayScale = geometry.scale
        stream.description.frame = frame
        for session in stream.audience?.sessions ?? [self] {
            session.connection.send(.streamMoved(streamID: stream.streamID, frame: frame, title: stream.description.title))
        }
    }

    // MARK: Dynamic resolution

    static let minimumDesktopSize = CGSize(width: 640, height: 400)
    /// 7680×4800 pixels at 2x; beyond that the encoder can't keep up anyway.
    static let maximumDesktopSize = CGSize(width: 3840, height: 2400)
    private var pendingDesktopSizes: [UInt16: CGSize?] = [:]

    private func scheduleDesktopSize(streamID: UInt16, size: CGSize?) {
        let scheduled = pendingDesktopSizes[streamID] != nil
        pendingDesktopSizes[streamID] = .some(size)
        guard !scheduled else { return }
        queue.async { [self] in
            guard let size = pendingDesktopSizes.removeValue(forKey: streamID) else { return }
            applyDesktopSize(streamID: streamID, size: size)
        }
    }

    /// Shows the desktop at the viewer's window size: a HiDPI virtual display
    /// of that size takes the display's place (the display mirrors it, and it
    /// is the main display if the display was), and is resized as the viewer
    /// window is. Like Screen Sharing's dynamic resolution, windows on the
    /// host rearrange for the new size. Everything is undone when the stream
    /// ends, the viewer turns it off, or this app quits.
    private func applyDesktopSize(streamID: UInt16, size requested: CGSize?) {
        guard let stream = streams[streamID], stream.description.role == .display else { return }
        // Shared: remembered for when this viewer leads; only the leader's applies.
        if let audience = stream.audience {
            stream.desktopSizes.updateValue(requested, forKey: sessionID)
            guard audience.leader === self else { return }
        }
        guard !stream.switchingDisplay else { return }
        // Viewing this same Mac, the viewer's window is on the display it would
        // resize: only displays made for testing take part.
        if Self.isLoopback, CGDisplayVendorNumber(stream.windowID) != VirtualDisplay.vendorID { return }
        guard let requested else {
            guard let standIn = stream.standIn else { return }
            stream.standIn = nil
            switchCapture(stream, to: stream.windowID)
            restore(display: stream.windowID, from: standIn)
            return
        }
        let size = CGSize(
            width: (min(max(requested.width, Self.minimumDesktopSize.width), Self.maximumDesktopSize.width) / 2).rounded() * 2,
            height: (min(max(requested.height, Self.minimumDesktopSize.height), Self.maximumDesktopSize.height) / 2).rounded() * 2)
        if let standIn = stream.standIn {
            guard standIn.pointSize != size else { return }
            if !standIn.resize(to: size) { log.error("dynamic resolution: resize to \(size.debugDescription, privacy: .public) failed") }
            return
        }
        // Already that size (and HiDPI): nothing to replace.
        let current = stream.description.frame.size
        if abs(current.width - size.width) < 2, abs(current.height - size.height) < 2, stream.displayScale >= 2 { return }
        // Another viewer's desktop already stands in for this display.
        guard CGDisplayMirrorsDisplay(stream.windowID) == kCGNullDirectDisplay else { return }
        guard let standIn = VirtualDisplay(pointSize: size, maximumPointSize: Self.maximumDesktopSize,
                                           name: "AnyRemote Desktop",
                                           productID: 0x100 + stream.windowID % 0xFF00) else { return }
        guard standIn.replace(stream.windowID) else {
            log.error("dynamic resolution: could not replace display \(stream.windowID)")
            return
        }
        stream.standIn = standIn
        switchCapture(stream, to: standIn.displayID)
    }

    private func switchCapture(_ stream: HostStream, to displayID: CGDirectDisplayID) {
        stream.switchingDisplay = true
        stream.captureDisplayID = displayID
        let sender = stream.sender
        Task { [weak stream] in
            do {
                try await sender.switchDisplay(to: displayID)
            } catch {
                log.error("display switch failed: \(error.localizedDescription, privacy: .public)")
            }
            queue.async { [self] in
                // The viewer that asked may have left; others may still watch.
                guard let stream, stream.audience?.sessions.isEmpty == false || streams[stream.streamID] === stream
                else { return }
                stream.switchingDisplay = false
                stream.displayScale = 0 // re-read: the stand-in is always 2x
                trackDisplay(stream)
            }
        }
    }

    private func restore(display: CGDirectDisplayID, from standIn: VirtualDisplay) {
        standIn.release(source: display)
        // Keep the stand-in alive until the capture has left it.
        queue.asyncAfter(deadline: .now() + 1) { withExtendedLifetime(standIn) {} }
    }

    private func startCursorMonitor() {
        guard cursor == nil else { return }
        let connection = connection
        let monitor = CursorMonitor { image in connection.send(.cursor(image)) }
        monitor.start()
        cursor = monitor
    }

    private func allocateStreamID() -> UInt16 {
        repeat {
            nextStreamID = nextStreamID == UInt16.max ? 1 : nextStreamID + 1
        } while isInUse(nextStreamID)
        return nextStreamID
    }

    /// Stream IDs are unique across sessions: a shared display keeps the IDs
    /// of the session that opened it.
    private func isInUse(_ id: UInt16) -> Bool {
        ([self] + (service?.sessions(except: self) ?? [])).contains {
            $0.streams[id] != nil || $0.tileOwners[id] != nil
        }
    }

    private func startStream(window: SCWindow, pid: pid_t, role: StreamDescription.Role, parent: UInt16?,
                             layer: Int, title: String, applicationName: String) {
        let streamID = allocateStreamID()
        let description = StreamDescription(streamID: streamID, windowID: window.windowID, role: role,
                                            parentStreamID: parent, frame: window.frame, layer: layer,
                                            title: title, applicationName: applicationName)
        let configuration = HEVCEncoder.Configuration(averageBitRate: role == .window ? Self.initialBitRate : 12_000_000,
                                                      alpha: role == .child)
        // Menus, popovers and alerts have glass that blurs what's behind
        // them; captured alone, it turns gray.
        let backdrop = role == .child
        let sender = WindowStreamSender(
            window: window, streamID: streamID, configuration: configuration,
            maximumDatagramSize: 1400 - DatagramEnvelope.overhead, backdrop: backdrop
        ) { [weak self] datagrams in
            self?.send(datagrams: datagrams)
        }
        let stream = HostStream(description: description, sender: sender, pid: pid,
                                bitRate: configuration.averageBitRate)
        stream.axWindow = role == .window ? try? AXWindow(pid: pid, windowID: window.windowID) : nil
        streams[streamID] = stream
        if let parent { streams[parent]?.children[window.windowID] = streamID }
        if role == .window { updateAudio() }
        sender.onStop = { [weak self] error in
            self?.queue.async {
                self?.endStream(streamID, reason: error == nil ? "Capture stopped." : "The window was closed.")
            }
        }
        if role == .window { prepareForStreaming(stream) }
        connection.send(.streamStarted(stream.description))
        if role == .window { sendControls(stream) }
        startCursorMonitor()
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
        sentCarets[streamID] = nil
        tileOwners = tileOwners.filter { $0.value != streamID }
        if let audience = stream.audience {
            let wasLeader = audience.leader === self
            audience.remove(self)
            stream.viewerBitRates[sessionID] = nil
            stream.desktopSizes[sessionID] = nil
            if let leader = audience.leader {
                // Others still watch: only this viewer stops.
                applyLowestBitRate(stream)
                if wasLeader {
                    leader.applyDesktopSize(streamID: streamID, size: stream.desktopSizes[leader.sessionID] ?? nil)
                }
                if notify { connection.send(.streamEnded(streamID: streamID, reason: reason)) }
                streamsMayHaveEnded()
                return
            }
        }
        for child in stream.children.values { endStream(child, reason: reason, notify: notify) }
        if let parent = stream.description.parentStreamID {
            streams[parent]?.children.removeValue(forKey: stream.windowID)
        }
        if let origin = stream.originalOrigin { try? stream.axWindow?.setPosition(origin) }
        if let standIn = stream.standIn {
            stream.standIn = nil
            restore(display: stream.windowID, from: standIn)
        }
        let sender = stream.sender
        Task { await sender.stop() }
        if notify { connection.send(.streamEnded(streamID: streamID, reason: reason)) }
        streamsMayHaveEnded()
    }

    private func streamsMayHaveEnded() {
        updateAudio()
        if !streams.values.contains(where: { $0.description.role != .child }) {
            dragBridge.cancel()
            transfer?.close()
            transfer = nil
            if injector.isPressed { injector.releaseAll(windowOrigin: .zero) }
            cursor?.stop()
            cursor = nil
            service?.streamsDidEnd(session: self)
        }
    }

    // MARK: Sound

    /// What the viewer should hear: everything with a desktop open, else the
    /// apps of its open windows; nothing without either.
    private var wantedAudioScope: AudioScope? {
        guard !ended, audioRequested else { return nil }
        let surfaces = streams.values.filter { $0.description.role != .child }
        guard !surfaces.isEmpty else { return nil }
        if surfaces.contains(where: { $0.description.role == .display }) { return .system }
        return .applications(Set(surfaces.map(\.pid)))
    }

    /// Starts, follows or stops the sound to match the viewer's surfaces and
    /// the host's settings. Queue-confined.
    func updateAudio() {
        let mutes = service?.settings.mutesSoundWhileShared ?? false
        guard let scope = wantedAudioScope else {
            stopAudio()
            return
        }
        if let audio {
            audio.tap.update(scope: scope, mutes: mutes)
            self.audio = (scope, audio.tap)
            return
        }
        let sender: AudioStreamSender
        do {
            sender = try AudioStreamSender { [weak self] datagram in self?.send(datagrams: [datagram]) }
        } catch {
            log.error("sound encoder unavailable: \(String(describing: error), privacy: .public)")
            return
        }
        let tap = ProcessAudioTap(scope: scope, mutes: mutes) { frames, rate, hostNanos in
            sender.submit(frames, sampleRate: rate, hostNanos: hostNanos)
        }
        audio = (scope, tap)
        // The viewer prepares its player while capture starts.
        connection.send(.audioStream(sender.format))
        log.notice("sending sound to \(self.viewerName, privacy: .public)")
        // Setting up the capture device takes ~80 ms; other sessions share this queue.
        let queue = queue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try tap.start()
            } catch {
                log.error("sound capture failed: \(error.localizedDescription, privacy: .public)")
                queue.async { [weak self] in
                    guard let self, self.audio?.tap === tap else { return }
                    self.audio = nil
                    self.connection.send(.audioStream(nil))
                }
            }
        }
    }

    private func stopAudio() {
        guard let audio else { return }
        self.audio = nil
        if !ended { connection.send(.audioStream(nil)) }
        DispatchQueue.global(qos: .userInitiated).async { audio.tap.stop() }
        log.notice("stopped sound to \(self.viewerName, privacy: .public)")
    }

    private func adaptBitRate(streamID: UInt16, received: UInt32, dropped: UInt32) {
        guard let stream = streams[streamID] else { return }
        let ceiling = switch stream.description.role {
        case .window: Self.maximumBitRate
        case .display: Self.displayMaximumBitRate
        case .child: 20_000_000
        }
        // Each viewer adapts its own rate; the stream runs at the lowest.
        var rate = stream.viewerBitRates[sessionID] ?? (stream.bitRate, 0)
        if dropped > 0 {
            rate.bitRate = max(Self.minimumBitRate, rate.bitRate * 3 / 4)
            rate.cleanReports = 0
        } else if received > 0 {
            rate.cleanReports += 1
            if rate.cleanReports >= 4 {
                rate.bitRate = min(ceiling, rate.bitRate + rate.bitRate / 10)
                rate.cleanReports = 0
            }
        }
        stream.viewerBitRates[sessionID] = rate
        applyLowestBitRate(stream)
    }

    private func applyLowestBitRate(_ stream: HostStream) {
        guard let bitRate = stream.viewerBitRates.values.map(\.bitRate).min(), bitRate != stream.bitRate else { return }
        stream.bitRate = bitRate
        stream.sender.setAverageBitRate(bitRate)
    }

    static let chip: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }()

    private func sendReports() {
        datagramLock.lock()
        let destination = peerAddress?.description ?? "none"
        datagramLock.unlock()
        if destination == "none", !streams.isEmpty {
            noDatagramsReports += 1
            // Once, after a few seconds: video is encoded but has nowhere to go.
            if noDatagramsReports == 3 {
                log.error("no UDP keepalives from \(self.viewerName, privacy: .public): video is not sent")
            }
        }
        for stream in streams.values {
            let summary: PipelineStats.Summary
            if let audience = stream.audience, audience.leader !== self {
                guard let last = stream.lastSummary else { continue }
                summary = last
            } else {
                summary = stream.sender.stats.drain()
                stream.lastSummary = summary
            }
            guard summary.framesPerSecond > 0 else { continue }
            connection.send(.hostReport(streamID: stream.streamID, HostStreamReport(
                captureP50: summary.p50[.capture] ?? 0, waitP50: summary.p50[.encodeWait] ?? 0,
                encodeP50: summary.p50[.encode] ?? 0, encodeP95: summary.p95[.encode] ?? 0,
                framesPerSecond: summary.framesPerSecond, megabitsPerSecond: summary.megabitsPerSecond,
                bitRate: stream.bitRate, chip: Self.chip, videoDestination: destination)))
        }
    }

    // MARK: Tracking (moves, titles, child windows)

    private func track() {
        // A shared display is followed by its first viewer, for everyone.
        for stream in streams.values where stream.description.role == .display
            && (stream.audience?.leader ?? self) === self { trackDisplay(stream) }
        let mains = streams.values.filter { $0.description.role == .window }
        if let launch = pendingLaunch, HostClock.nowNanos() > launch.deadline { pendingLaunch = nil }
        guard !mains.isEmpty else {
            // Nothing to follow, but an app opened from the viewer may still bring its window.
            if pendingLaunch != nil { openNewWindows(WindowServerWindow.onScreen()) } else { knownWindows = nil }
            return
        }
        checkWindowStates(mains)
        let onScreen = WindowServerWindow.onScreen()
        var byID: [CGWindowID: WindowServerWindow] = [:]
        for window in onScreen { byID[window.id] = window }
        openNewWindows(onScreen)

        for main in mains {
            guard let current = byID[main.windowID] else {
                checkGone(main)
                continue
            }
            main.offScreenSince = nil
            updateFrame(main, frame: current.frame, title: current.title)
            updateSharingIndicator(main, frame: current.frame, onScreen: onScreen)
            trackChildren(of: main, mainFrame: current.frame, onScreen: onScreen)
        }
        for stream in streams.values where stream.description.role == .child {
            if let current = byID[stream.windowID] { updateFrame(stream, frame: current.frame, title: current.title) }
        }
    }

    /// Many apps close a window by ordering it out and keep it for later, so
    /// capture goes on (with its last image) and nothing reports the close.
    /// A window that stays off screen is gone for the viewer: its mirror
    /// closes, instead of showing a stale image whose clicks would land on
    /// whatever is behind on the host. Minimizing is undone separately and
    /// comes back within the grace period.
    private func checkGone(_ stream: HostStream) {
        let now = HostClock.nowNanos()
        guard let since = stream.offScreenSince else {
            stream.offScreenSince = now
            return
        }
        guard now - since >= Self.offScreenGrace else { return }
        if stream.minimizedOnHost { return }
        if stream.description.role == .display {
            log.notice("display \(stream.windowID) went away; ending its stream")
            for session in stream.audience?.sessions ?? [self] {
                session.endStream(stream.streamID, reason: "The display is no longer available.")
            }
            return
        }
        log.notice("window \(stream.windowID) left the screen; ending its stream")
        endStream(stream.streamID, reason: "The window was closed.")
    }

    private static let offScreenGrace: UInt64 = 700_000_000

    private func updateFrame(_ stream: HostStream, frame: CGRect, title: String) {
        let title = title.isEmpty ? stream.description.title : title
        guard frame.origin != stream.description.frame.origin || frame.size != stream.description.frame.size
            || title != stream.description.title else { return }
        let resized = frame.size != stream.description.frame.size
        stream.description.frame = frame
        stream.sender.windowFrameChanged(frame)
        if resized, stream.description.role == .window { sendControls(stream) }
        stream.description.title = title
        connection.send(.streamMoved(streamID: stream.streamID, frame: frame, title: title))
    }

    // MARK: Title bar buttons and window state

    /// macOS 27 covers a captured window's close, minimize and zoom buttons
    /// with a purple sharing indicator: a small window of the captured app
    /// that the window server also composites into the capture. The viewer
    /// draws its own buttons there, so the indicator is painted over.
    private func updateSharingIndicator(_ stream: HostStream, frame: CGRect, onScreen: [WindowServerWindow]) {
        var rect: CGRect?
        if let button = stream.controls?.close ?? stream.controls?.minimize ?? stream.controls?.zoom {
            let anchor = CGPoint(x: frame.minX + button.midX, y: frame.minY + button.midY)
            let indicator = onScreen.first {
                $0.pid == stream.pid && $0.id != stream.windowID && $0.layer == 0
                    && $0.frame.width <= 120 && $0.frame.height <= 40 && $0.frame.contains(anchor)
            }
            // A little more on each side takes in its antialiased edge and its shadow.
            rect = indicator.map { $0.frame.offsetBy(dx: -frame.minX, dy: -frame.minY).insetBy(dx: -2, dy: -3) }
        }
        guard rect != stream.concealedRect else { return }
        stream.concealedRect = rect
        stream.sender.setConcealedRect(rect)
        log.debug("sharing indicator of window \(stream.windowID): \(String(describing: rect), privacy: .public)")
    }

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
            let streamID = stream.streamID
            poller.run("state \(streamID)", pid: stream.pid, reply: queue) {
                (minimized: window.isMinimized, fullScreen: window.isFullScreen)
            } then: { [weak self] state in
                guard let self, let stream = streams[streamID] else { return }
                stream.minimizedOnHost = state.minimized
                if state.minimized {
                    poller.run("restore \(streamID)", pid: stream.pid, reply: queue) { window.setMinimized(false) } then: { _ in }
                    connection.send(.windowStateRequest(streamID: streamID, .minimize))
                } else if state.fullScreen {
                    poller.run("restore \(streamID)", pid: stream.pid, reply: queue) { window.setFullScreen(false) } then: { _ in }
                    connection.send(.windowStateRequest(streamID: streamID, .enterFullScreen))
                }
            }
        }
    }

    /// A window that appears right after the viewer clicked or typed is one
    /// the viewer caused: a new document, a preferences window, or another
    /// app's window such as Finder revealing a file. It opens on the viewer
    /// like a window picked from the list. Windows that show up on their own
    /// stay on the host.
    private func openNewWindows(_ onScreen: [WindowServerWindow]) {
        let now = HostClock.nowNanos()
        let current = Self.trackedWindowIDs(onScreen)
        if let known = knownWindows {
            let recentInput = now - lastInputTime < Self.causedWindowInterval
            let launchPID = pendingLaunch?.pid
            for window in onScreen where current.contains(window.id) && !known.contains(window.id)
                && (recentInput || (launchPID != nil && window.pid == launchPID)) {
                newWindowCandidates[window.id] = now
            }
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
                  standardWindowIDs(pid: window.pid, after: seen)?.contains(window.id) == true else { continue }
            newWindowCandidates[window.id] = nil
            if window.pid == pendingLaunch?.pid { pendingLaunch = nil }
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
            // An input method's candidates, next to the window being typed into.
            if !samePID, isInputMethodWindow(window) {
                if window.frame.intersects(near) { candidates.append(window) }
                continue
            }
            let panelService = !samePID && Self.panelServiceNames.contains { window.ownerName.contains($0) }
            guard samePID || panelService else { continue }
            if window.layer == 0 {
                // Tiny layer-0 helpers (the text input source indicator, ...)
                // are not part of the window's UI, unless they hold the text
                // being edited (Finder's rename field is a window of its own).
                guard window.frame.intersects(near) else { continue }
                if window.frame.width < 80 || window.frame.height < 30 {
                    guard samePID, window.frame.width >= 16, window.frame.height >= 12, holdsFocusedText(window)
                    else { continue }
                }
                if samePID { needsStandardIDs = true }
                candidates.append(window)
            } else if window.layer > 0, window.layer < 1000, window.layer != 24, window.layer != 25 {
                candidates.append(window)
            }
        }
        if needsStandardIDs {
            // Until the app has said which are its own windows, none of its
            // layer-0 windows is taken for a child.
            let standard = standardWindowIDs(pid: main.pid)
            candidates.removeAll { $0.layer == 0 && $0.pid == main.pid && standard?.contains($0.id) != false }
        }
        let wanted = Set(candidates.prefix(Self.maximumChildren).map(\.id))

        for (windowID, streamID) in main.children where !wanted.contains(windowID) {
            endStream(streamID, reason: "Child window closed.")
        }
        let missing = candidates.prefix(Self.maximumChildren).filter { main.children[$0.id] == nil }
        guard !missing.isEmpty else { return }
        for window in missing {
            log.notice("child window \(window.id) of \(main.windowID): layer \(window.layer) pid \(window.pid) \(window.frame.debugDescription, privacy: .public)")
        }
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

    /// The app's standard window IDs as last answered, asked again in the
    /// background when older than half a second (or than `after`, a window's
    /// first sighting). Nil while the app hasn't answered since `after`.
    private func standardWindowIDs(pid: pid_t, after: UInt64 = 0) -> Set<CGWindowID>? {
        let now = HostClock.nowNanos()
        let cached = standardWindowCache[pid]
        if cached == nil || now - cached!.asked >= 500_000_000 || cached!.asked < after {
            poller.run("standard \(pid)", pid: pid, reply: queue) {
                AXWindow.standardWindowIDsIfAnswered(pid: pid)
            } then: { [weak self] ids in
                guard let self else { return }
                // A busy app that didn't answer keeps its last known windows.
                standardWindowCache[pid] = (ids ?? standardWindowCache[pid]?.ids, now)
                if standardWindowCache.count > 64 { standardWindowCache = standardWindowCache.filter { $0.key == pid } }
            }
        }
        guard let cached, cached.asked >= after else { return nil }
        return cached.ids
    }

    // MARK: Input

    private func inject(_ event: InputEvent, streamID: UInt16) {
        guard let stream = streams[streamID], stream.description.role != .child else { return }
        // The whole desktop: points are relative to the display, nothing to
        // focus or keep in place, and windows it opens stay on it.
        prepareKeyboard(for: event)
        if stream.description.role == .display {
            if stream.offScreenSince != nil, case .mouseDown = event { return }
            let wasPressed = injector.isPressed
            injector.post(event, windowOrigin: stream.description.frame.origin)
            trackPress(event, streamID: streamID, wasPressed: wasPressed)
            scheduleCaretLookup(after: event, streamID: streamID)
            return
        }
        // The window is closing or closed: don't let the viewer's pointer and
        // keys reach whatever is now at its place. A release still goes
        // through, so no button stays held.
        if stream.offScreenSince != nil {
            switch event {
            case .mouseUp: break
            case .key(_, false, _, _), .flagsChanged: break
            default: return
            }
        }
        var origin = stream.description.frame.origin
        switch event {
        case .mouseDown, .mouseUp, .key(_, true, _, _), .text:
            lastInputTime = HostClock.nowNanos()
        default:
            break
        }
        switch event {
        case .mouseDown:
            let current = WindowServerWindow.describe(stream.windowID)
            guard let current, current.isOnScreen else {
                stream.offScreenSince = stream.offScreenSince ?? HostClock.nowNanos()
                return
            }
            focus(stream, force: false)
            origin = current.frame.origin
            if !injector.isPressed { stream.pressFrame = stream.description.frame }
            setTrackerFast(true)
        case .key(_, true, _, _), .text:
            focus(stream, force: false)
        default:
            break
        }
        let wasPressed = injector.isPressed
        injector.post(event, windowOrigin: origin)
        trackPress(event, streamID: streamID, wasPressed: wasPressed)
        scheduleCaretLookup(after: event, streamID: streamID)
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

    /// A left press may start a drag here, which the viewer then takes over.
    private func trackPress(_ event: InputEvent, streamID: UInt16, wasPressed: Bool) {
        switch event {
        case let .mouseDown(_, button, _, _, _) where button == .left && !wasPressed:
            dragBridge.pressBegan(streamID: streamID)
        case .mouseUp where wasPressed && !injector.isPressed:
            dragBridge.pressEnded()
        default:
            break
        }
    }

    /// Where a stream's surface is now (global top-left points), for drags.
    private func surfaceOrigin(_ streamID: UInt16) -> CGPoint? {
        guard let stream = streams[streamID] else { return nil }
        switch stream.description.role {
        case .display:
            return stream.description.frame.origin
        case .window:
            return WindowServerWindow.describe(stream.windowID)?.frame.origin ?? stream.description.frame.origin
        case .child:
            return nil
        }
    }

    /// This session's transfer connection arrived (see `HostService.attachTransfer`).
    func adoptTransfer(_ connection: ControlConnection, token: Data) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !ended, let transferToken, token == transferToken else {
            log.error("transfer connection with an unknown token")
            connection.close()
            return
        }
        transfer?.close()
        let channel = FileTransferChannel(connection: connection)
        let bridge = dragBridge
        channel.resolve = { dragID, itemID, reply in bridge.resolve(dragID: dragID, itemID: itemID, reply: reply) }
        transfer = channel
        bridge.transfer = channel
        log.notice("transfer connection joined")
    }

    /// With the viewer's input method, typing needs a plain keyboard layout here (see `HostKeyboardLayout`).
    private func prepareKeyboard(for event: InputEvent) {
        guard textInput.composesOnViewer else { return }
        switch event {
        case .key(_, true, _, _), .text: ensureKeyboardLayout()
        default: break
        }
    }

    // MARK: Caret

    /// Looks up the caret once typing or a click may have moved it, and tells
    /// the viewer when it changed. At most one lookup is pending, so fast
    /// typing updates it a few times a second rather than once per key.
    private func scheduleCaretLookup(after event: InputEvent, streamID: UInt16) {
        let delay: Int
        switch event {
        case .mouseDown, .mouseUp, .key(_, true, _, _), .text: lastInputStreamID = streamID
        default: break
        }
        switch event {
        case .key(_, true, _, _), .text: delay = 60
        case .mouseUp: delay = 120
        default: return
        }
        lastCaretInput = HostClock.nowNanos()
        guard !caretLookupPending else {
            caretLookupStale = true
            return
        }
        caretLookupPending = true
        queue.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in self?.lookUpCaret() }
    }

    private func lookUpCaret() {
        caretLookupStale = false
        // The stream that has the host's focus: the last one given input.
        guard let streamID = lastInputStreamID, let stream = streams[streamID] else {
            caretLookupPending = false
            return
        }
        let pid: pid_t? = stream.description.role == .display ? nil : stream.pid
        let locator = caretLocator
        caretQueue.async { [weak self] in
            let caret = locator.caret(pid: pid)
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.sendCaret(caret, streamID: streamID)
                // Keys typed during the lookup may have moved the caret again,
                // and the app may still be reacting to the last input (Finder
                // opens its rename field after Return): look again for half a
                // second after it.
                let reacting = HostClock.nowNanos() - self.lastCaretInput < 500_000_000
                if self.caretLookupStale || reacting {
                    let delay = self.caretLookupStale ? 40 : 150
                    self.queue.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in self?.lookUpCaret() }
                } else {
                    self.caretLookupPending = false
                }
            }
        }
    }

    private struct CaretState: Equatable {
        var rect: CGRect?
        var font: CaretFont?
    }

    private func sendCaret(_ caret: (rect: CGRect, font: CaretFont?)?, streamID: UInt16) {
        guard !ended, let stream = streams[streamID] else { return }
        let frame = stream.description.frame
        // A caret in another window of the app, or off this display, is no use here.
        var state = CaretState()
        if let caret, frame.insetBy(dx: -4, dy: -4).intersects(caret.rect) {
            state = CaretState(rect: caret.rect.offsetBy(dx: -frame.minX, dy: -frame.minY), font: caret.font)
        }
        if sentCarets[streamID] == state { return }
        sentCarets[streamID] = state
        connection.send(.caret(streamID: streamID, rect: state.rect, font: state.font))
    }

    private enum InputMethodProcess {
        case none, inputMethod, sourceIndicator
    }

    /// Input methods run as processes of their own, from an Input Methods
    /// folder (WeChat, Sogou, Rime, Apple's own, the accent popup). macOS
    /// shows the input source indicator at the caret from TextInputUI: worth
    /// seeing when the viewer switches the host's input method, noise when
    /// only this host's own switch to a keyboard layout set it off.
    private func isInputMethodWindow(_ window: WindowServerWindow) -> Bool {
        switch inputMethodProcess(window.pid) {
        case .none: false
        case .inputMethod: true
        case .sourceIndicator: !textInput.composesOnViewer
        }
    }

    private func inputMethodProcess(_ pid: pid_t) -> InputMethodProcess {
        if let known = inputMethodProcesses[pid] { return known }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = length > 0 ? String(cString: buffer) : ""
        let kind: InputMethodProcess = path.contains("/Input Methods/") || path.lowercased().contains(".inputmethod.")
            ? .inputMethod : path.contains("TextInputUI") ? .sourceIndicator : .none
        if inputMethodProcesses.count > 256 { inputMethodProcesses.removeAll() }
        inputMethodProcesses[pid] = kind
        return kind
    }

    /// Whether a small window of the app holds its focused text field: an
    /// inline editor (Finder's rename field) rather than an indicator. Checked
    /// again until it says yes, since focus moves in just after the window shows.
    private func holdsFocusedText(_ window: WindowServerWindow) -> Bool {
        let now = HostClock.nowNanos()
        if let known = textEditorWindows[window.id], known.holdsFocus || now - known.checked < 300_000_000 {
            return known.holdsFocus
        }
        let locator = caretLocator
        let windowID = window.id, frame = window.frame
        poller.run("focus \(windowID)", pid: window.pid, reply: queue) {
            locator.focusedElementFrame(pid: window.pid)
        } then: { [weak self] focused in
            guard let self else { return }
            let holds = focused.map { frame.insetBy(dx: -2, dy: -2).contains($0) } ?? false
            textEditorWindows[windowID] = (holds, now)
            if textEditorWindows.count > 64 {
                textEditorWindows = textEditorWindows.filter { now - $0.value.checked < 10_000_000_000 }
            }
        }
        return textEditorWindows[window.id]?.holdsFocus ?? false
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
    /// Development: controlling this Mac from itself, activating the host app
    /// takes the menu bar and key window away from the viewer.
    private static let skipsFocus = ProcessInfo.processInfo.environment["ANYREMOTE_NO_HOST_FOCUS"] != nil

    private func focus(_ stream: HostStream, force: Bool) {
        guard !Self.skipsFocus else { return }
        let now = HostClock.nowNanos()
        if !force, now - lastFocusCheck < 300_000_000 { return }
        lastFocusCheck = now
        // Development loopback: the viewer's windows on this same Mac don't count.
        let front = WindowServerWindow.onScreen().first {
            $0.layer == 0 && !(Self.isLoopback && $0.ownerName.hasPrefix("AnyRemote"))
        }
        guard force || front?.id != stream.windowID else { return }
        // The app's own fields and panels over it (Finder's rename field, its
        // little helper windows) are part of it: raising the window would end
        // what happens in them. Only another real window needs it raised.
        if !force, let front, front.pid == stream.pid,
           standardWindowIDs(pid: stream.pid)?.contains(front.id) != true { return }
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
