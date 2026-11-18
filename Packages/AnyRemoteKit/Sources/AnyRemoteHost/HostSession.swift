import AnyRemoteMedia
import AnyRemoteNetwork
import AnyRemoteWindowControl
import AnyRemoteWire
import AppKit
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
    /// Where the window was before it was moved onto a virtual display.
    var originalOrigin: CGPoint?
    /// The virtual display it is on (one per viewer screen).
    var virtualDisplayID: CGDirectDisplayID?
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
    /// Main windows: in full screen on the host, as Accessibility last answered.
    var fullScreenOnHost = false
    /// Main windows: the size the viewer asked for while the window was in
    /// full screen, applied once it leaves.
    var sizeAfterFullScreen: CGSize?
    /// Main windows: when the viewer asked for full screen, until the window
    /// is in it; resizes meanwhile would disturb its transition.
    var fullScreenRequested: UInt64?
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
    var viewerBitRates: [UInt32: ViewerRateControl] = [:]
    /// Shared streams: each viewer's dynamic-resolution request (nil: off);
    /// the first viewer's is applied.
    var desktopSizes: [UInt32: CGSize?] = [:]
    /// Shared streams: the first viewer drains the statistics, the others read this.
    var lastSummary: PipelineStats.Summary?
    /// Popups: the menu bar item that opened it.
    var statusItemID: String?

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
    /// Layer-0 windows that came on screen in the last moment, by first
    /// sighting: one of them may be the tab taking a streamed window's place.
    private var recentArrivals: [CGWindowID: UInt64] = [:]
    private var lastCandidateCheck: UInt64 = 0
    /// When a streamed window last went in or out of full screen on the host.
    /// Its move to a Space of its own takes every other window off the
    /// screen, and they come back when it leaves: neither is a window closing
    /// or a new window opening.
    private var lastHostFullScreen: UInt64 = 0
    /// The newest window on screen at the last tracking pass, and as of the
    /// last full-screen change. Window numbers only grow, so a window no newer
    /// than that, showing up around a full-screen change, is one coming back
    /// from the other Space rather than one just opened. (Keeping a list of
    /// the windows that left missed some, and they all opened on the viewer.)
    private var newestWindowID: CGWindowID = 0
    private var newestWindowIDAtFullScreen: CGWindowID = 0
    /// Child windows whose capture couldn't start, by when; not tried again
    /// for a while (Chrome's hidden full-screen toolbar windows were tried,
    /// and opened and closed on the viewer, on every tracking pass).
    private var failedChildren: [CGWindowID: UInt64] = [:]
    /// An app the viewer asked to open. Opened from the app list (`allWindows`)
    /// all its windows come to the viewer, as clicking its Dock icon brings
    /// them all forward; opened for a notification, only the window it shows.
    private var pendingLaunch: (path: String, pid: pid_t?, deadline: UInt64, allWindows: Bool)?
    /// An app whose streamed window the viewer's input just closed. The
    /// window that replaces it (Chrome's browser window after its profile
    /// picker, an app's main window after a welcome window) opens on the
    /// viewer too, even when the app takes a while to show it.
    private var awaitingSuccessor: (pid: pid_t, deadline: UInt64)?
    /// The viewer's screen in use: the one it connected from, then that of
    /// the window it last focused. New windows go to its virtual display.
    private var viewerScreen: ViewerScreen?
    private var ended = false
    /// The key the viewer connected with (nil: the legacy code), so
    /// revoking it ends this session. Queue-confined.
    private(set) var credentialID: String?
    /// The viewer wants the sound of what it shows.
    private var audioRequested = false
    /// The viewer's own cap on each stream's bit rate (nil: none).
    private var bitRateLimit: Int?
    /// Frames a second the viewer wants (`ControlMessage.frameRate`).
    private var frameRate = FrameRate.standard
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
    /// System prompts on screen, shown with the window in use.
    private var promptWindowIDs: Set<CGWindowID> = []
    /// System prompts brought over the window in use, at the size they had.
    private var movedPrompts: [CGWindowID: CGSize] = [:]
    /// Whose input method composes; the viewer says once connected.
    private var textInput = TextInputSettings(composesOnViewer: true)
    /// Processes and whether they are input methods (their candidate windows
    /// belong with the window being typed into).
    private var inputMethodProcesses: [pid_t: InputMethodProcess] = [:]

    /// The viewer's transfer connection presents this to join the session.
    private var transferToken: Data?
    private var transfer: FileTransferChannel?
    private var awaitingTransfer: [@Sendable (FileTransferChannel?) -> Void] = []
    private var clipboard: SharedClipboard.Peer?
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
        queue.async { service.followAppActors() }
    }

    // MARK: Lifecycle

    func secured(_ info: SecureSessionInfo) {
        credentialID = info.credentialID
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
            guard case let .authenticate(viewerName, takeOver, screen) = message else {
                connection.close(after: .rejected(reason: "Expected authentication."))
                return
            }
            self.viewerName = viewerName
            viewerScreen = screen
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
        case let .listWindows(requestID):
            listWindows(requestID: requestID)
        case let .openWindow(windowID):
            openWindow(windowID)
        case let .openDisplay(displayID):
            openDisplay(displayID)
        case let .desktopSize(streamID, size):
            scheduleDesktopSize(streamID: streamID, size: size)
        case let .listApplications(requestID):
            listApplications(requestID: requestID)
        case let .launchApplication(path):
            launchApplication(path, allWindows: true)
        case let .quitApplication(path, force):
            quitApplication(path, force: force)
        case let .peerPairing(pairing):
            receivePeerPairing(pairing)
        case let .pasteboardSharing(enabled):
            setPasteboardSharing(enabled)
        case let .pasteboardOffer(offer):
            clipboard?.receive(offer)
        case let .closeStream(streamID):
            endStream(streamID, reason: "Closed by viewer.", notify: false)
        case let .requestKeyframe(streamID):
            // A strip's receiver asks for that strip only.
            streams[tileOwners[streamID] ?? streamID]?.sender.requestRecoveryKeyframe(streamID: streamID)
        case let .receiverReport(streamID, received, dropped, queuing):
            if let owner = tileOwners[streamID] {
                // Strips: the first one's reports pace the stream; loss or a queue in any backs it off.
                adaptBitRate(streamID: owner, received: 0, dropped: dropped, queuingMilliseconds: queuing)
            } else {
                adaptBitRate(streamID: streamID, received: received, dropped: dropped, queuingMilliseconds: queuing)
            }
        case let .resize(streamID, size):
            scheduleResize(streamID: streamID, size: size)
        case let .focus(streamID, screen):
            if let screen { viewerScreen = screen }
            if let stream = streams[streamID] {
                if let screen { follow(stream, to: screen) }
                focus(stream, force: true)
            }
        case let .input(streamID, event):
            inject(event, streamID: streamID)
        case let .requestMenuBar(streamID):
            readMenuBar(streamID: streamID)
        case let .performMenuItem(streamID, path):
            performMenuItem(streamID: streamID, path: path)
        case let .windowAction(streamID, action):
            perform(action, streamID: streamID)
        case let .maximumBitRate(limit):
            setBitRateLimit(limit)
        case let .frameRate(rate):
            setFrameRate(rate)
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
        case .notices(let subscription):
            service?.notices.subscribe(self, subscription)
        case let .listStatusItems(requestID):
            service?.statusItems.list(reply: queue) { [weak self] items in
                self?.connection.send(.statusItems(requestID: requestID, items: items))
            }
        case let .openStatusItem(id):
            openStatusItem(id)
        case let .performStatusItemMenu(id, path):
            service?.statusItems.finishMenu(id, path: path)
        case let .openNotification(id, path):
            // Launching first notes the windows on screen, so one the click opens comes here.
            if let path { launchApplication(path, allWindows: false) }
            service?.notices.open(id: id)
        case .goodbye:
            end(reason: "Viewer disconnected.")
        default:
            log.debug("unexpected message from viewer")
        }
    }

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
        clipboard?.leave()
        clipboard = nil
        guard enabled else { return }
        let connection = connection
        // The viewer sends its clipboard when sharing starts; this side waits for a copy.
        clipboard = SharedClipboard.shared.join(
            sendingCurrent: false,
            send: { connection.send(.pasteboardOffer($0)) },
            fetch: { [weak self] offerID, item, type, reply in
                guard let self else { return reply(nil) }
                self.withTransfer { transfer in
                    guard let transfer else { return reply(nil) }
                    transfer.fetchPasteboard(offerID: offerID, item: item, type: type, completion: reply)
                }
            })
    }

    /// Runs `body` with the transfer connection, once it's there (nil if
    /// the session ends first): the viewer's first clipboard offer may
    /// arrive before it.
    private func withTransfer(_ body: @escaping @Sendable (FileTransferChannel?) -> Void) {
        queue.async { [self] in
            if let transfer { return body(transfer) }
            if ended { return body(nil) }
            awaitingTransfer.append(body)
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
            for body in awaitingTransfer { body(nil) }
            awaitingTransfer.removeAll()
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
                                      missingPermissions: missing, version: service?.versionInfo)
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

    private func listWindows(requestID: UInt32) {
        let service = service
        let connection = connection
        Task {
            do {
                let summaries = try await HostWindows.shareable(excludingPID: ProcessInfo.processInfo.processIdentifier,
                                                                includeOwnWindowIDs: service?.includedOwnWindowIDs ?? [])
                    .map(\.1)
                let displays = await MainActor.run {
                    HostWindows.displays(virtualDisplayIDs: service?.virtualDisplayIDs ?? [])
                }
                connection.send(.windowList(requestID: requestID, windows: summaries, displays: displays,
                                            missingPermissions: Self.missingPermissions()))
            } catch {
                log.error("window list failed: \(error.localizedDescription, privacy: .public)")
                connection.send(.windowList(requestID: requestID, windows: [], displays: [],
                                            missingPermissions: Self.missingPermissions()))
            }
        }
    }

    // MARK: Applications

    private func listApplications(requestID: UInt32) {
        let connection = connection
        Task { @MainActor in
            connection.send(.applicationList(requestID: requestID, applications: HostApplications.list()))
        }
    }

    /// The images the viewer asked for over the transfer connection, in
    /// order, nil where there is none. Only windows it may open have thumbnails.
    private nonisolated static func images(_ images: [HostImage], service: HostService?,
                                           reply: @escaping @Sendable ([Data?]) -> Void) {
        Task {
            var result = [Data?](repeating: nil, count: images.count)
            var thumbnailSizes: [UInt32: Int] = [:]
            for case let .thumbnail(windowID, maximumPixels) in images { thumbnailSizes[windowID] = maximumPixels }
            var thumbnails: [UInt32: Data] = [:]
            if !thumbnailSizes.isEmpty,
               let windows = try? await HostWindows.shareable(excludingPID: ProcessInfo.processInfo.processIdentifier,
                                                              includeOwnWindowIDs: service?.includedOwnWindowIDs ?? [])
                .map(\.0).filter({ thumbnailSizes[$0.windowID] != nil }) {
                for size in Set(thumbnailSizes.values) {
                    let matching = windows.filter { thumbnailSizes[$0.windowID] == size }
                    thumbnails.merge(await HostWindows.thumbnails(for: matching, maximumPixels: min(size, 1024))) { $1 }
                }
            }
            let icons = await MainActor.run { () -> [Int: Data] in
                var icons: [Int: Data] = [:]
                for (index, image) in images.enumerated() {
                    switch image {
                    case .applicationIcon(let path): icons[index] = service?.applicationIcon(path: path)
                    case .windowIcon(let bundle): icons[index] = service?.windowIcon(bundleIdentifier: bundle)
                    case .thumbnail: break
                    }
                }
                return icons
            }
            for (index, image) in images.enumerated() {
                if case .thumbnail(let windowID, _) = image { result[index] = thumbnails[windowID] }
                else { result[index] = icons[index] }
            }
            reply(result)
        }
    }

    private func launchApplication(_ path: String, allWindows: Bool) {
        let now = HostClock.nowNanos()
        pendingLaunch = (path, nil, now + 20_000_000_000, allWindows)
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
                service?.appActors.note(.viewer(sessionID), pid: pid)
                // Already running: no new window may come; show the ones it has.
                queue.asyncAfter(deadline: .now() + 1) { [self] in openExistingWindows(pid: pid) }
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
        log.notice("peer pairing from \(pairing.name, privacy: .public) at \(address ?? "Bonjour", privacy: .public): \(pairing.credential == nil ? "withdrawn" : "offered", privacy: .public)")
        let callback = service?.onPeerPairing
        DispatchQueue.main.async { callback?(pairing, address) }
    }

    /// The launched app's windows on screen: its front one, or all of them.
    /// Minimized windows and those on other Spaces stay on the host, as they
    /// would here.
    private func openExistingWindows(pid: pid_t) {
        guard let launch = pendingLaunch, launch.pid == pid else { return }
        let streamed = Set(streams.values.map(\.windowID))
        let standard = AXWindow.standardWindowIDs(pid: pid)
        // On-screen windows come front to back.
        let windows = WindowServerWindow.onScreen().filter {
            $0.pid == pid && $0.layer == 0 && standard.contains($0.id) && !streamed.contains($0.id)
        }
        guard let front = windows.first else { return }
        guard launch.allWindows else {
            pendingLaunch = nil
            openWindow(front.id)
            return
        }
        settleLaunch()
        // Back to front: the viewer brings each new mirror forward, so the
        // front window ends up in front there too.
        openWindows(windows.reversed().map(\.id))
    }

    /// The launched app has shown a window: windows it restores along with
    /// it still come for a moment, later ones only as caused by input.
    private func settleLaunch() {
        guard let launch = pendingLaunch else { return }
        guard launch.allWindows else {
            pendingLaunch = nil
            return
        }
        pendingLaunch?.deadline = min(launch.deadline, HostClock.nowNanos() + Self.launchSettleInterval)
    }

    private static let launchSettleInterval: UInt64 = 2_000_000_000

    private static func trackedWindowIDs(_ onScreen: [WindowServerWindow]) -> Set<CGWindowID> {
        let ownPID = getpid()
        return Set(onScreen.lazy.filter { $0.layer == 0 && $0.pid != ownPID }.map(\.id))
    }

    // MARK: Streams

    /// Opens several windows in this order, looked up together so they start
    /// in it.
    private func openWindows(_ windowIDs: [CGWindowID]) {
        let ids = windowIDs.filter { id in
            !openingWindows.contains(id)
                && !streams.values.contains { $0.windowID == id && $0.description.role == .window }
        }
        guard ids.count > 1 else {
            ids.first.map(openWindow)
            return
        }
        openingWindows.formUnion(ids)
        Task { [self] in
            let windows = (try? await HostWindows.scWindows(ids: Set(ids))) ?? [:]
            queue.async { [self] in
                openingWindows.subtract(ids)
                guard !ended else { return }
                for id in ids {
                    guard let window = windows[id], let app = window.owningApplication else { continue }
                    let summary = HostWindows.summary(window, app: app)
                    startStream(window: window, pid: app.processID, role: .window, parent: nil, layer: 0,
                                title: summary.title, applicationName: summary.applicationName)
                }
            }
        }
    }

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
        let configuration = HEVCEncoder.Configuration(averageBitRate: initialBitRate(for: .display),
                                                      expectedFrameRate: frameRate)
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
        // This viewer's cap may be below what the others let the stream run at.
        stream.viewerBitRates[sessionID] = ViewerRateControl(bitRate: min(stream.bitRate, bitRateCeiling(for: .display)))
        applyLowestBitRate(stream)
        updateAudio()
        log.notice("\(self.viewerName, privacy: .public) joins display \(stream.windowID) (\(audience.sessions.count) watching)")
        connection.send(.streamStarted(stream.description))
        stream.sender.requestKeyframe()
        startCursorMonitor()
    }

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
                                           refreshRate: Double(frameRate), name: "AnyRemote Desktop",
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
        let configuration = HEVCEncoder.Configuration(averageBitRate: initialBitRate(for: role),
                                                      expectedFrameRate: frameRate,
                                                      alpha: role == .child || role == .popup)
        // Menus, popovers and alerts have glass that blurs what's behind
        // them; captured alone, it turns gray.
        let backdrop = role == .child || role == .popup
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
        if role == .window {
            // Its app works for the viewer now, which has it on screen.
            service?.appActors.note(.viewer(sessionID), pid: pid)
            updateAudio()
        }
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
                    if role == .child { failedChildren[window.windowID] = HostClock.nowNanos() }
                    endStream(streamID, reason: "Capture failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Moves the window onto the virtual display for the viewer's screen in
    /// use, when the settings call for them (see `RemoteDisplays`).
    private func prepareForStreaming(_ stream: HostStream) {
        guard let service, let target = service.remoteWindowTarget(for: viewerScreen, refreshRate: frameRate),
              let ax = stream.axWindow, let origin = ax.position else { return }
        stream.virtualDisplayID = target.displayID
        stream.originalOrigin = homeOrigin(from: origin, size: ax.size)
        guard !target.frame.contains(CGPoint(x: origin.x + 1, y: origin.y + 1)) else { return }
        Self.move(ax, into: target.frame)
    }

    /// Where the window goes back to once the viewer stops showing it:
    /// `origin` if it is on this Mac's own screens, else (a window the app
    /// opened on a virtual display, like a second Finder window opened with
    /// ⌘N) the middle of this Mac's main screen, where this Mac's user can
    /// find it.
    private func homeOrigin(from origin: CGPoint, size: CGSize?) -> CGPoint {
        let point = CGPoint(x: origin.x + 1, y: origin.y + 1)
        let virtual = service?.virtualDisplayIDs ?? []
        guard virtual.contains(where: { CGDisplayBounds($0).contains(point) }) else { return origin }
        let main = CGDisplayBounds(CGMainDisplayID())
        let frame = service?.visibleFrame(containing: CGPoint(x: main.midX, y: main.midY)) ?? main
        let size = size ?? .zero
        return CGPoint(x: (frame.midX - min(size.width, frame.width) / 2).rounded(),
                       y: max(frame.minY, (frame.midY - min(size.height, frame.height) / 2).rounded()))
    }

    /// The viewer's window is on `screen`: the host window moves to that
    /// screen's virtual display, so it can grow to that screen's size and
    /// fill it in full screen. Not while in full screen: its Space belongs
    /// to the display it is on.
    private func follow(_ stream: HostStream, to screen: ViewerScreen) {
        guard stream.description.role == .window, let current = stream.virtualDisplayID, !stream.fullScreenOnHost,
              stream.fullScreenRequested == nil, let service, let ax = stream.axWindow,
              let target = service.remoteWindowTarget(for: screen, refreshRate: frameRate), target.displayID != current else { return }
        log.notice("window \(stream.windowID) follows the viewer to another screen")
        stream.virtualDisplayID = target.displayID
        // The click that focused the mirror may be pressed still; this move
        // isn't a drag of the window to undo (see `keepInPlace`).
        stream.pressFrame = nil
        if stream.originalOrigin == nil, let origin = ax.position {
            stream.originalOrigin = homeOrigin(from: origin, size: ax.size)
        }
        Self.move(ax, into: target.frame)
    }

    /// Top-left of `frame`, no larger than it.
    private static func move(_ ax: AXWindow, into frame: CGRect) {
        try? ax.setPosition(CGPoint(x: frame.minX, y: frame.minY))
        if let size = ax.size, size.width > frame.width || size.height > frame.height {
            try? ax.setSize(CGSize(width: min(size.width, frame.width), height: min(size.height, frame.height)))
        }
    }

    /// Puts windows back onto the virtual displays macOS took them off (see
    /// `RemoteDisplays.restoreArrangement`): `targets` are the frames
    /// windows may take on the displays put back. Queue-confined.
    func returnWindows(to targets: [CGDirectDisplayID: CGRect]) {
        for stream in streams.values where stream.description.role == .window {
            guard let id = stream.virtualDisplayID, let target = targets[id], let ax = stream.axWindow,
                  let origin = ax.position, !target.contains(CGPoint(x: origin.x + 1, y: origin.y + 1)) else { continue }
            log.notice("window \(stream.windowID) left its virtual display; moving it back")
            Self.move(ax, into: target)
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
        // Closed on the viewer (or the session ended): close it on the host too,
        // by clicking its menu bar item again.
        if stream.description.role == .popup, !notify, let item = stream.statusItemID,
           WindowServerWindow.describe(stream.windowID)?.isOnScreen == true {
            service?.statusItems.toggle(item)
        }
        for child in stream.children.values { endStream(child, reason: reason, notify: notify) }
        if let parent = stream.description.parentStreamID {
            streams[parent]?.children.removeValue(forKey: stream.windowID)
        }
        if let origin = stream.originalOrigin, let ax = stream.axWindow {
            // A full-screen window leaves its Space on the virtual display
            // first; the display's removal would otherwise take the Space
            // along to this Mac's screen. Asked of the window itself: the
            // state polled for the viewer may not have caught up.
            poller.run("put back \(streamID)", pid: stream.pid, reply: queue) { () -> Bool in
                guard ax.isFullScreen else { return false }
                ax.setFullScreen(false)
                return true
            } then: { [queue] wasFullScreen in
                queue.asyncAfter(deadline: .now() + (wasFullScreen ? 1.5 : 0)) { [weak self] in
                    try? ax.setPosition(origin)
                    // It may have grown to the viewer's screen meanwhile.
                    if let frame = self?.service?.visibleFrame(containing: CGPoint(x: origin.x + 1, y: origin.y + 1)) {
                        Self.move(ax, into: CGRect(origin: origin, size: CGSize(width: frame.maxX - origin.x,
                                                                                height: frame.maxY - origin.y)))
                    }
                }
            }
        }
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
            // The transfer connection stays: the viewer's lists and clipboard use it without windows open.
            dragBridge.cancel()
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

    private func adaptBitRate(streamID: UInt16, received: UInt32, dropped: UInt32, queuingMilliseconds: Double?) {
        guard let stream = streams[streamID] else { return }
        let ceiling = bitRateCeiling(for: stream.description.role)
        // Each viewer adapts its own rate; the stream runs at the lowest.
        var rate = stream.viewerBitRates[sessionID] ?? ViewerRateControl(bitRate: min(stream.bitRate, ceiling))
        let before = rate.bitRate
        rate.report(received: received, dropped: dropped, queuingMilliseconds: queuingMilliseconds,
                    floor: min(Self.minimumBitRate, ceiling), ceiling: ceiling, now: HostClock.nowNanos())
        if rate.bitRate < before, dropped == 0 {
            log.info("\(self.viewerName, privacy: .public): \(Int(queuingMilliseconds ?? 0)) ms queued in the network, video \(before / 1_000_000) → \(rate.bitRate / 1_000_000) Mbps")
        }
        stream.viewerBitRates[sessionID] = rate
        applyLowestBitRate(stream)
    }

    /// The most a stream of `role` may use for this viewer: the host's own
    /// ceiling, or the viewer's cap when lower.
    private func bitRateCeiling(for role: StreamDescription.Role) -> Int {
        let ceiling = switch role {
        case .window: Self.maximumBitRate
        case .display: Self.displayMaximumBitRate
        case .child, .popup: 20_000_000
        }
        return min(ceiling, bitRateLimit ?? .max)
    }

    private func initialBitRate(for role: StreamDescription.Role) -> Int {
        let initial = switch role {
        case .window: Self.initialBitRate
        case .display: Self.displayInitialBitRate
        case .child, .popup: 12_000_000
        }
        return min(initial, bitRateCeiling(for: role))
    }

    /// Applies a new cap to every stream this viewer watches right away: a
    /// lower one cuts the rate at once; a higher one lifts it at least to
    /// where a new stream would start, rather than climbing 10% at a time.
    private func setBitRateLimit(_ limit: Int?) {
        let raised = (limit ?? .max) > (bitRateLimit ?? .max)
        bitRateLimit = limit.map { max(Self.minimumBitRate, $0) }
        log.notice("\(self.viewerName, privacy: .public) caps video at \(self.bitRateLimit.map { "\($0 / 1_000_000) Mbps" } ?? "automatic", privacy: .public)")
        for stream in streams.values {
            let role = stream.description.role
            let current = stream.viewerBitRates[sessionID]?.bitRate ?? stream.bitRate
            let bitRate = min(raised ? max(current, initialBitRate(for: role)) : current, bitRateCeiling(for: role))
            stream.viewerBitRates[sessionID] = ViewerRateControl(bitRate: bitRate)
            applyLowestBitRate(stream)
        }
    }

    /// The viewer's new frame rate, for every stream it watches and the
    /// displays they are on, right away.
    private func setFrameRate(_ rate: Int) {
        let rate = FrameRate.clamped(rate)
        guard rate != frameRate else { return }
        frameRate = rate
        log.notice("\(self.viewerName, privacy: .public) wants \(rate) fps")
        service?.setRemoteDisplayRefreshRate(rate)
        for stream in streams.values {
            stream.sender.setFrameRate(rate)
            stream.standIn?.setRefreshRate(Double(rate))
        }
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
        trackPopups()
        let mains = streams.values.filter { $0.description.role == .window }
        if let launch = pendingLaunch, HostClock.nowNanos() > launch.deadline { pendingLaunch = nil }
        if let successor = awaitingSuccessor, HostClock.nowNanos() > successor.deadline { awaitingSuccessor = nil }
        guard !mains.isEmpty else {
            // Nothing to follow, but an app opened from the viewer may still
            // bring its window, and the virtual displays may stay without
            // windows (see `HostService.streamsDidEnd`): one an app opens
            // there for this Mac's user goes back to its screens.
            if pendingLaunch != nil || awaitingSuccessor != nil || !(service?.virtualDisplayIDs.isEmpty ?? true) {
                openNewWindows(WindowServerWindow.onScreen())
            } else {
                knownWindows = nil
            }
            return
        }
        checkWindowStates(mains)
        let onScreen = WindowServerWindow.onScreen()
        var byID: [CGWindowID: WindowServerWindow] = [:]
        for window in onScreen { byID[window.id] = window }
        followTabs(mains, onScreen: onScreen, byID: byID)
        openNewWindows(onScreen)

        promptWindowIDs = Set(onScreen.lazy.filter { Self.systemPromptOwners.contains($0.ownerName) }.map(\.id))
        // System prompts go with the window in use: the one last clicked
        // or typed in, else any.
        let promptHolder = lastInputStreamID.flatMap { id in mains.first { $0.streamID == id && byID[$0.windowID] != nil } }
            ?? mains.first { byID[$0.windowID] != nil }
        for main in mains {
            guard let current = byID[main.windowID] else {
                checkGone(main)
                continue
            }
            main.offScreenSince = nil
            updateFrame(main, frame: current.frame, title: current.title)
            updateSharingIndicator(main, frame: current.frame, onScreen: onScreen)
            trackChildren(of: main, mainFrame: current.frame, onScreen: onScreen, takesPrompts: main === promptHolder)
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
            if stream.description.role == .window, now - lastInputTime < Self.causedWindowInterval {
                awaitingSuccessor = (stream.pid, now + Self.successorInterval)
            }
            return
        }
        guard now - since >= Self.offScreenGrace else { return }
        if stream.minimizedOnHost || now - lastHostFullScreen < Self.spaceSwitchInterval { return }
        // Off the screen because another streamed window has a full-screen Space.
        if streams.values.contains(where: { $0.fullScreenOnHost && $0.offScreenSince == nil }) { return }
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

    // MARK: Tabs

    /// Each tab of an app using macOS's native tabs (Ghostty, Terminal,
    /// Safari, Finder…) is a window of its own: choosing another tab orders
    /// the shown one out and the chosen one in, in the same place. Closing
    /// the streamed window and opening the other as a new one made the
    /// viewer's window flash on every tab switch, so the stream moves to the
    /// window that took the streamed one's place: another window of the
    /// same app, arriving with the same frame as it leaves. The viewer's
    /// window stays and shows the other tab. An app that replaces a window
    /// with another in the same place is followed the same way.
    private func followTabs(_ mains: [HostStream], onScreen: [WindowServerWindow],
                            byID: [CGWindowID: WindowServerWindow]) {
        let now = HostClock.nowNanos()
        if let known = knownWindows {
            for id in Self.trackedWindowIDs(onScreen) where !known.contains(id) && recentArrivals[id] == nil {
                recentArrivals[id] = now
            }
        }
        recentArrivals = recentArrivals.filter { byID[$0.key] != nil && now - $0.value < Self.tabArrivalInterval }
        guard !recentArrivals.isEmpty else { return }
        var taken = Set(streams.values.map(\.windowID))
        for main in mains where byID[main.windowID] == nil && !main.minimizedOnHost {
            guard let tab = onScreen.first(where: {
                recentArrivals[$0.id] != nil && !taken.contains($0.id) && Self.isTab($0, of: main)
            }) else { continue }
            taken.insert(tab.id)
            handOff(main, to: tab)
        }
    }

    /// The arrival may come a moment before the streamed window leaves, or after.
    private static let tabArrivalInterval: UInt64 = 1_000_000_000

    /// Tabs of a window share its frame.
    private static func isTab(_ window: WindowServerWindow, of main: HostStream) -> Bool {
        let frame = main.description.frame
        return window.pid == main.pid && window.layer == 0 && window.alpha > 0.01
            && abs(window.frame.minX - frame.minX) <= 2 && abs(window.frame.minY - frame.minY) <= 2
            && abs(window.frame.width - frame.width) <= 2 && abs(window.frame.height - frame.height) <= 2
    }

    /// A window that just arrived where a streamed window of its app is: not
    /// a new window to open while it may turn out to be a tab taking that
    /// one's place.
    private func mayBeTab(_ window: WindowServerWindow) -> Bool {
        recentArrivals[window.id] != nil && streams.values.contains {
            $0.description.role == .window && Self.isTab(window, of: $0)
        }
    }

    private func handOff(_ stream: HostStream, to window: WindowServerWindow) {
        let streamID = stream.streamID
        log.notice("window \(window.id) takes the place of window \(stream.windowID) (a tab); its stream follows")
        // Children (menus, popovers, sheets) belonged to the other tab.
        for childID in Array(stream.children.values) where childID != 0 {
            endStream(childID, reason: "Child window closed.")
        }
        stream.children = [:]
        stream.sender.ignoreCaptureStop()
        stream.description.windowID = window.id
        stream.description.frame = window.frame
        if !window.title.isEmpty { stream.description.title = window.title }
        stream.axWindow = try? AXWindow(pid: stream.pid, windowID: window.id)
        stream.offScreenSince = nil
        stream.controls = nil
        stream.concealedRect = nil
        recentArrivals[window.id] = nil
        newWindowCandidates[window.id] = nil
        if awaitingSuccessor?.pid == stream.pid { awaitingSuccessor = nil }
        connection.send(.streamMoved(streamID: streamID, frame: window.frame, title: stream.description.title,
                                     windowID: window.id))
        sendControls(stream)
        Task { [self] in
            let captured = try? await HostWindows.scWindow(id: window.id)
            queue.async { [self] in
                // Another tab may have been chosen meanwhile.
                guard let stream = streams[streamID], stream.windowID == window.id else { return }
                guard let captured else {
                    endStream(streamID, reason: "The window was closed.")
                    return
                }
                stream.sender.switchWindow(to: captured) { [self] error in
                    guard let error else { return }
                    log.error("capture of tab \(window.id) failed: \(error.localizedDescription, privacy: .public)")
                    queue.async { self.endStream(streamID, reason: "Capture failed: \(error.localizedDescription)") }
                }
            }
        }
    }

    /// How long a window closed by the viewer's input waits for its app's next window.
    private static let successorInterval: UInt64 = 15_000_000_000

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
        case .enterFullScreen:
            // Only where it takes a Space of the virtual display: on this
            // Mac's own screens it would take its windows off them.
            guard !stream.fullScreenOnHost, let window = stream.axWindow,
                  let displays = service?.virtualDisplayIDs, !displays.isEmpty,
                  displays.contains(where: { CGDisplayBounds($0).contains(CGPoint(x: stream.description.frame.midX,
                                                                                  y: stream.description.frame.midY)) })
            else { return }
            stream.fullScreenRequested = HostClock.nowNanos()
            poller.run("enter full screen \(streamID)", pid: stream.pid, reply: queue) { window.setFullScreen(true) } then: { _ in }
            // An app without full screen: the window takes the size asked for meanwhile.
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, let stream = streams[streamID], stream.fullScreenRequested != nil,
                      !stream.fullScreenOnHost else { return }
                stream.fullScreenRequested = nil
                if let size = stream.sizeAfterFullScreen {
                    stream.sizeAfterFullScreen = nil
                    scheduleResize(streamID: streamID, size: size)
                }
            }
        case .exitFullScreen:
            guard stream.fullScreenOnHost, let window = stream.axWindow else { return }
            poller.run("exit full screen \(streamID)", pid: stream.pid, reply: queue) { window.setFullScreen(false) } then: { _ in }
        }
    }

    /// A streamed window that got minimized on the host (Window › Minimize,
    /// ⌘M, a title bar double-click) is put back and the viewer minimizes its
    /// local window instead. Full screen stays (see `HostWindowStateRequest`):
    /// the viewer's window follows the host window in and out.
    private func checkWindowStates(_ mains: [HostStream]) {
        let now = HostClock.nowNanos()
        guard now - lastStateCheck >= 150_000_000 else { return }
        lastStateCheck = now
        for stream in mains {
            guard let window = stream.axWindow else { continue }
            let streamID = stream.streamID
            // In full screen the buttons are in the toolbar that slides down
            // from the top, which moves them without resizing the window:
            // the viewer follows them there to show its buttons over them.
            let followsButtons = stream.fullScreenOnHost
            poller.run("state \(streamID)", pid: stream.pid, reply: queue) {
                (minimized: window.isMinimized, fullScreen: window.isFullScreen,
                 controls: followsButtons ? window.controlFrames : nil)
            } then: { [weak self] state in
                guard let self, let stream = streams[streamID] else { return }
                if let frames = state.controls, stream.fullScreenOnHost {
                    let controls = WindowControls(close: frames.close, minimize: frames.minimize, zoom: frames.zoom,
                                                  fullScreen: frames.fullScreen)
                    if controls != stream.controls {
                        stream.controls = controls
                        connection.send(.windowControls(streamID: streamID, controls))
                    }
                }
                stream.minimizedOnHost = state.minimized
                if state.minimized {
                    poller.run("restore \(streamID)", pid: stream.pid, reply: queue) { window.setMinimized(false) } then: { _ in }
                    connection.send(.windowStateRequest(streamID: streamID, .minimize))
                } else if state.fullScreen != stream.fullScreenOnHost {
                    stream.fullScreenOnHost = state.fullScreen
                    stream.fullScreenRequested = nil
                    lastHostFullScreen = HostClock.nowNanos()
                    newestWindowIDAtFullScreen = max(newestWindowIDAtFullScreen, newestWindowID)
                    log.notice("window \(stream.windowID) \(state.fullScreen ? "entered" : "left", privacy: .public) full screen")
                    connection.send(.windowStateRequest(streamID: streamID, state.fullScreen ? .enterFullScreen : .exitFullScreen))
                    if !state.fullScreen, let size = stream.sizeAfterFullScreen {
                        stream.sizeAfterFullScreen = nil
                        scheduleResize(streamID: streamID, size: size)
                    }
                }
            }
        }
    }

    /// Notes a click, key press or menu command going to this app, which
    /// acts for the viewer from now on.
    private func noteInput(pid: pid_t) {
        lastInputTime = HostClock.nowNanos()
        service?.appActors.note(.viewer(sessionID), pid: pid)
    }

    /// A new window opens on the viewer when it is the viewer's: its app
    /// acts for this viewer (see `AppActors`), because the viewer clicked
    /// or typed in it last, opened one of its windows, or launched it (from
    /// the app list, or a document double-clicked in its Finder), or the
    /// viewer just launched the app or closed the window this one replaces.
    /// What this Mac's user, a script or a background app opens stays on
    /// this Mac and can be opened from the picker. No time limit decides
    /// this: a window an app opens on its own after the viewer's click stays
    /// unless the viewer acted on that app, and a window of the app the
    /// viewer uses comes whenever it opens.
    ///
    /// A window that isn't the viewer's but came up on a virtual display
    /// moves to this Mac's screens: macOS puts a new window on the display
    /// in use, which is often the viewer's, and an app reopens its windows
    /// where they were, so this Mac's user would launch an app and not see
    /// its window.
    private func openNewWindows(_ onScreen: [WindowServerWindow]) {
        let now = HostClock.nowNanos()
        let current = Self.trackedWindowIDs(onScreen)
        if let known = knownWindows {
            let spaceSwitch = now - lastHostFullScreen < Self.spaceSwitchInterval
                || streams.values.contains { $0.fullScreenOnHost }
            for window in onScreen where current.contains(window.id) && !known.contains(window.id)
                && !(spaceSwitch && window.id <= newestWindowIDAtFullScreen) {
                newWindowCandidates[window.id] = now
            }
        }
        knownWindows = current
        newestWindowID = max(newestWindowID, onScreen.lazy.map(\.id).max() ?? 0)
        guard !newWindowCandidates.isEmpty, now - lastCandidateCheck >= 100_000_000 else { return }
        lastCandidateCheck = now
        let streamed = Set(streams.values.filter { $0.description.role == .window }.map(\.windowID))
        let virtualDisplays = (service?.virtualDisplayIDs ?? []).map { CGDisplayBounds($0) }
        // A new window is often listed before it has its final size and
        // before Accessibility knows it, so look again for a moment. Until
        // then it may have been taken for a child of the app's other window
        // (Chrome's browser window, opened from its profile picker); it then
        // becomes a window of its own, which outlives the other one. Whom
        // its app acts for is looked at each time too (see `AppActors.actor`).
        for window in onScreen {
            guard let seen = newWindowCandidates[window.id] else { continue }
            if streamed.contains(window.id) || now - seen > 3_000_000_000 {
                newWindowCandidates[window.id] = nil
                continue
            }
            let actor = service?.appActors.actor(of: window.pid)
            let forViewer = window.pid == pendingLaunch?.pid || window.pid == awaitingSuccessor?.pid
                || actor == .viewer(sessionID)
            if !forViewer {
                // Another viewer's window is that session's to open.
                if case .viewer = actor { continue }
                let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
                // Development loopback: the viewer's own mirrors may be on them.
                guard virtualDisplays.contains(where: { $0.contains(center) }),
                      !Self.systemPromptOwners.contains(window.ownerName),
                      !(Self.isLoopback && window.ownerName.hasPrefix("AnyRemote")),
                      now - seen >= Self.launcherNoteInterval else { continue }
            }
            guard window.frame.width >= 160, window.frame.height >= 100, window.alpha > 0.01, !mayBeTab(window),
                  !Self.panelServiceNames.contains(where: { window.ownerName.contains($0) }),
                  standardWindowIDs(pid: window.pid, after: seen)?.contains(window.id) == true else { continue }
            newWindowCandidates[window.id] = nil
            guard forViewer else {
                sendHome(window)
                continue
            }
            if window.pid == pendingLaunch?.pid { settleLaunch() }
            if window.pid == awaitingSuccessor?.pid { awaitingSuccessor = nil }
            for main in streams.values where main.description.role == .window {
                guard let childID = main.children.removeValue(forKey: window.id), childID != 0 else { continue }
                endStream(childID, reason: "Child window closed.")
            }
            log.notice("opening new window \(window.id) of \(window.ownerName, privacy: .public)")
            openWindow(window.id)
        }
        newWindowCandidates = newWindowCandidates.filter { current.contains($0.key) }
    }

    /// How long a window that isn't the viewer's stays where it opened
    /// before it is moved off a virtual display: LaunchServices may note
    /// the app that launched its app, which may make it the viewer's, a
    /// moment after the window shows.
    private static let launcherNoteInterval: UInt64 = 300_000_000

    /// Moves a window off the virtual displays, to the middle of this Mac's
    /// main screen.
    private func sendHome(_ window: WindowServerWindow) {
        guard let ax = try? AXWindow(pid: window.pid, windowID: window.id) else { return }
        let origin = homeOrigin(from: window.frame.origin, size: window.frame.size)
        log.notice("window \(window.id) of \(window.ownerName, privacy: .public) opened on a virtual display for no viewer; moving it to this Mac's screen")
        try? ax.setPosition(origin)
    }

    private static let causedWindowInterval: UInt64 = 3_000_000_000

    /// How long a host full screen keeps windows from counting as closed or
    /// new: the animations there and back, plus the state poll in between.
    private static let spaceSwitchInterval: UInt64 = 4_000_000_000

    /// Every active display's bounds, in global points (top-left origin).
    private static func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    private static let panelServiceNames = ["OpenAndSavePanelService", "Open and Save Panel Service"]

    /// Processes that show macOS's own prompts: a keychain or administrator
    /// password, Touch ID, a privacy permission, an app from the internet.
    /// They belong to no opened window, so on their own they would never
    /// reach the viewer, and they open where macOS likes, often on a virtual
    /// display nobody looks at. They are brought over the window in use and
    /// shown as its child, so they can be answered from the other Mac.
    static let systemPromptOwners: Set<String> = [
        "SecurityAgent", "coreautha", "UserNotificationCenter", "CoreServicesUIAgent", "universalAccessAuthWarn",
    ]

    private func trackChildren(of main: HostStream, mainFrame: CGRect, onScreen: [WindowServerWindow],
                               takesPrompts: Bool) {
        let near = mainFrame.insetBy(dx: -400, dy: -400)
        var candidates: [WindowServerWindow] = []
        var needsStandardIDs = false
        // Mirroring one of our own windows: our mirrors and child panels are
        // same-PID windows too, and capturing them would feed back.
        let ownAllowed = main.pid == getpid() ? service?.includedOwnWindowIDs ?? [] : nil
        let now = HostClock.nowNanos()
        failedChildren = failedChildren.filter { now - $0.value < 5_000_000_000 }
        let displays = Self.displayBounds()
        for window in onScreen where window.id != main.windowID && window.alpha > 0.01 {
            if let ownAllowed, window.pid == main.pid, window.layer == 0, !ownAllowed.contains(window.id) { continue }
            // Mostly off every display: parked out of sight, like Chrome's
            // toolbar strips above a full-screen window until the pointer
            // reaches the top. Their mirrors can't be placed off the
            // viewer's screen, so they would sit as empty bars on top of it.
            let shown = displays.reduce(0) { area, display in
                let part = display.intersection(window.frame)
                return part.isNull ? area : area + part.width * part.height
            }
            guard window.frame.width >= 4, window.frame.height >= 4, failedChildren[window.id] == nil,
                  shown >= window.frame.width * window.frame.height / 2 else { continue }
            // A same-app window over the whole window (Chrome's in full
            // screen) shows nothing the window's own stream doesn't.
            if window.pid == main.pid, window.layer == 0, window.frame.contains(mainFrame) { continue }
            // Full screen on a display of its own, the window is captured
            // with its display, which shows what lies on it already (Chrome's
            // toolbar layer, a link's address, menus). Mirrors of those would
            // be pushed below the viewer's menu bar strip, a line across the
            // top of the page.
            if main.fullScreenOnHost, mainFrame.contains(window.frame) { continue }
            let samePID = window.pid == main.pid
            if !samePID, Self.systemPromptOwners.contains(window.ownerName) {
                if takesPrompts, window.frame.width >= 100, window.frame.height >= 50 {
                    bringPrompt(window, over: mainFrame)
                    candidates.append(window)
                }
                continue
            }
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
            // layer-0 windows is taken for a child; nor, for a window that
            // just appeared, before the app has answered since.
            let newest = candidates.lazy.filter { $0.layer == 0 && $0.pid == main.pid }
                .compactMap { self.newWindowCandidates[$0.id] }.max() ?? 0
            let standard = standardWindowIDs(pid: main.pid, after: newest)
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

    /// Moves a system prompt over the window in use: centred on it, a third
    /// of the way down, inside its display. Again when it grows (it is first
    /// seen small, while it animates open), but not otherwise, so it can be
    /// dragged away. Its process has to be active for Accessibility to list
    /// the prompt; it would take the focus anyway.
    private func bringPrompt(_ window: WindowServerWindow, over mainFrame: CGRect) {
        if let size = movedPrompts[window.id],
           abs(size.width - window.frame.width) < 20, abs(size.height - window.frame.height) < 20 { return }
        if movedPrompts.count > 64 { movedPrompts.removeAll() }
        movedPrompts[window.id] = window.frame.size
        let display = Self.displayBounds().first { $0.contains(CGPoint(x: mainFrame.midX, y: mainFrame.midY)) }
        var target = CGPoint(x: mainFrame.midX - window.frame.width / 2,
                             y: mainFrame.minY + max(0, (mainFrame.height - window.frame.height) / 3))
        if let display {
            target.x = min(max(target.x, display.minX), display.maxX - window.frame.width)
            target.y = min(max(target.y, display.minY + 30), display.maxY - window.frame.height)
        }
        guard abs(target.x - window.frame.minX) > 2 || abs(target.y - window.frame.minY) > 2 else { return }
        let (pid, windowID, owner, point) = (window.pid, window.id, window.ownerName, target)
        poller.run("prompt \(windowID) \(Int(window.frame.width))x\(Int(window.frame.height))", pid: pid, reply: queue) {
            var ax = try? AXWindow(pid: pid, windowID: windowID)
            if ax == nil {
                NSRunningApplication(processIdentifier: pid)?.activate()
                usleep(300_000)
                ax = try? AXWindow(pid: pid, windowID: windowID)
            }
            return (try? ax?.setPosition(point)) != nil
        } then: { [weak self] moved in
            if !moved { self?.movedPrompts[windowID] = nil }
            log.notice("system prompt \(windowID) of \(owner, privacy: .public) \(moved ? "moved over the window in use" : "couldn't be moved")")
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
        if stream.description.role == .popup {
            injector.post(event, windowOrigin: stream.description.frame.origin)
            return
        }
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
            noteInput(pid: stream.pid)
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
        case let .gesture(_, kind, phase, value, _):
            // Gestures go to the frontmost app only, so a pinch on a window
            // that wasn't clicked yet makes it frontmost first, as a key does.
            log.debug("gesture \(kind.rawValue, privacy: .public) phase \(phase) value \(value)")
            if kind == .smartMagnify || phase & UInt32(NSEvent.Phase.began.rawValue) != 0 {
                focus(stream, force: false)
            }
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

    // MARK: Menu bar items

    /// Clicks a menu bar item for the viewer. Its menu goes back to be shown
    /// there natively; a popover or panel it opens is streamed as a popup;
    /// a window it opens comes as a mirror.
    private func openStatusItem(_ id: String) {
        guard let pid = StatusItemReader.pid(of: id), let service else { return }
        service.appActors.note(.viewer(sessionID), pid: pid)
        let before = Set(WindowServerWindow.onScreen().lazy.filter { $0.pid == pid }.map(\.id))
        service.statusItems.open(id, reply: queue) { [weak self] menu in
            guard let self else { return }
            if let menu {
                connection.send(.statusItemMenu(id: id, menus: menu))
            } else {
                awaitStatusItemWindow(id: id, pid: pid, before: before, deadline: HostClock.nowNanos() + 1_200_000_000)
            }
        }
    }

    private func awaitStatusItemWindow(id: String, pid: pid_t, before: Set<CGWindowID>, deadline: UInt64) {
        let opened = WindowServerWindow.onScreen().filter {
            $0.pid == pid && !before.contains($0.id) && $0.alpha > 0.01 && $0.frame.width >= 20 && $0.frame.height >= 20
                && $0.layer != 25
        }
        if let popup = opened.first(where: { $0.layer != 0 }) {
            log.notice("menu bar item \(id, privacy: .public) opened popup \(popup.id) layer \(popup.layer)")
            Task { [self] in
                let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                queue.async { [self] in
                    guard let window = content?.windows.first(where: { $0.windowID == popup.id }) else { return }
                    startStream(window: window, pid: pid, role: .popup, parent: nil, layer: popup.layer,
                                title: popup.title, applicationName: popup.ownerName)
                    streams.values.first { $0.windowID == popup.id && $0.description.role == .popup }?.statusItemID = id
                }
            }
        } else if let window = opened.first {
            openWindow(window.id)
        } else if HostClock.nowNanos() < deadline {
            queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
                self?.awaitStatusItemWindow(id: id, pid: pid, before: before, deadline: deadline)
            }
        }
    }

    /// Popups end when they close on the host, and follow it when it moves.
    private func trackPopups() {
        for popup in streams.values where popup.description.role == .popup {
            guard let current = WindowServerWindow.describe(popup.windowID), current.isOnScreen else {
                endStream(popup.streamID, reason: "Closed.")
                continue
            }
            if current.frame != popup.description.frame {
                popup.description.frame = current.frame
                connection.send(.streamMoved(streamID: popup.streamID, frame: current.frame, title: current.title))
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
        case .popup:
            return stream.description.frame.origin
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
        let service = service
        channel.provideImages = { images, reply in Self.images(images, service: service, reply: reply) }
        channel.providePasteboard = { [weak self] offerID, item, type, reply in
            guard let clipboard = self?.clipboard else { return reply(nil) }
            clipboard.provide(offerID: offerID, item: item, type: type, reply: reply)
        }
        transfer = channel
        for body in awaitingTransfer { body(channel) }
        awaitingTransfer.removeAll()
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
        guard !stream.fullScreenOnHost else { return }
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
        // A system prompt shown with this window has the focus, and must
        // keep it: typing meant for a password field would otherwise go to
        // the app.
        if !force, stream.children.keys.contains(where: { promptWindowIDs.contains($0) }) { return }
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
        let inFullScreen = stream.fullScreenOnHost || stream.fullScreenRequested != nil
        guard let ax = stream.axWindow, !inFullScreen else {
            // A full-screen window keeps the screen's size until it leaves.
            if inFullScreen { stream.sizeAfterFullScreen = requested }
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
        noteInput(pid: stream.pid)
        focus(stream, force: true)
        let pid = stream.pid
        menuQueue.async {
            if !MenuBarReader.perform(pid: pid, path: path) {
                log.error("menu item \(path, privacy: .public) could not be pressed")
            }
        }
    }
}
