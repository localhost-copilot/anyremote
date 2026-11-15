import AnyRemoteNetwork
import AnyRemoteWindowControl
import AnyRemoteWire
import AppKit
import Foundation
import Network
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Host")

/// The host agent: accepts viewers, streams windows, injects their input.
///
/// One viewer controls the host at a time; a second viewer is refused unless
/// it asks to take over, which ends the first session.
public final class HostService: @unchecked Sendable {
    public struct Options: Sendable {
        /// Overrides the configured port (0 = ephemeral).
        public var port: UInt16?
        public var advertise: Bool
        public init(port: UInt16? = nil, advertise: Bool = true) {
            self.port = port
            self.advertise = advertise
        }
    }

    public struct Status: Sendable, Equatable {
        public var isListening = false
        public var port: UInt16?
        public var viewerName: String?
        public var error: String?
    }

    public let settingsStore: HostSettingsStore
    private let options: Options
    private let queue = DispatchQueue(label: "anyremote.host", qos: .userInteractive)
    private let socketQueue = DispatchQueue(label: "anyremote.host.udp", qos: .userInteractive)
    private let lock = NSLock()

    private var listener: ControlListener?
    private(set) var socket: DatagramSocket?
    private var pending: [UInt32: HostSession] = [:]
    private var active: HostSession?
    private var iconCache: [String: Data] = [:]
    private var applicationIconCache: [String: Data] = [:]
    private var virtualDisplay: VirtualDisplay?
    private var ownWindowIDs: Set<CGWindowID> = []
    private var status = Status()

    /// Called on the main queue.
    public var onStatusChange: (@MainActor @Sendable (Status) -> Void)?

    public init(settings: HostSettingsStore = HostSettingsStore(), options: Options = Options()) {
        self.settingsStore = settings
        self.options = options
    }

    var settings: HostSettings { settingsStore.settings }

    public var currentStatus: Status {
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    // MARK: Start / stop

    public func start() throws {
        stop()
        let settings = settingsStore.settings
        let socket = try DatagramSocket(bindingPort: 0, queue: socketQueue)
        socket.onReceive = { [weak self] batch in self?.route(batch) }
        socket.resume()
        let listener = try ControlListener(port: options.port ?? settings.port,
                                           serviceName: options.advertise ? ComputerName.current : nil,
                                           hostID: settings.hostID, queue: queue)
        listener.onConnection = { [weak self] connection in self?.accept(connection) }
        listener.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.updateStatus { $0.isListening = true; $0.port = listener.port; $0.error = nil }
                log.notice("host listening on \(listener.port ?? 0) (udp \(socket.localPort))")
            case .failed(let error):
                self.updateStatus { $0.isListening = false; $0.error = error.localizedDescription }
            case .cancelled:
                self.updateStatus { $0.isListening = false }
            default:
                break
            }
        }
        listener.start()
        lock.lock()
        self.socket = socket
        self.listener = listener
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        let listener = self.listener
        let socket = self.socket
        let sessions = Array(pending.values) + [active].compactMap { $0 }
        self.listener = nil
        self.socket = nil
        pending.removeAll()
        active = nil
        lock.unlock()
        sessions.forEach { $0.end(reason: "Remote control was turned off.", notifyViewer: true) }
        listener?.cancel()
        socket?.cancel()
        updateStatus { $0 = Status() }
    }

    public var port: UInt16? { listener?.port }
    var datagramPort: UInt16 { socket?.localPort ?? 0 }

    /// Ends the active session, e.g. from the host's own UI.
    public func disconnectViewer() {
        lock.lock()
        let session = active
        lock.unlock()
        session?.end(reason: "The host ended the session.", notifyViewer: true)
    }

    /// Lets windows of this process be listed (diagnostics workloads).
    public func allowOwnWindow(_ id: CGWindowID) {
        lock.lock()
        ownWindowIDs.insert(id)
        lock.unlock()
    }

    var includedOwnWindowIDs: Set<CGWindowID> {
        lock.lock()
        defer { lock.unlock() }
        return ownWindowIDs
    }

    // MARK: Sessions

    private func accept(_ connection: NWConnection) {
        let sessionID = UInt32.random(in: 1...UInt32.max)
        let store = settingsStore
        let control = ControlConnection(
            connection: connection,
            role: .host(code: { store.settings.isEnabled ? store.settings.code : nil },
                        hostID: store.settings.hostID, hostName: ComputerName.current, sessionID: sessionID),
            queue: queue
        )
        let session = HostSession(sessionID: sessionID, connection: control, queue: queue, service: self)
        control.onSecured = { [weak session] info in session?.secured(info) }
        control.onMessage = { [weak session] message in session?.handle(message) }
        control.onClose = { [weak self, weak session] error in
            guard let session else { return }
            session.end(reason: error.map { "Connection lost: \($0.localizedDescription)" } ?? "Viewer disconnected.")
            self?.forget(session)
        }
        lock.lock()
        pending[sessionID] = session
        lock.unlock()
        control.start()
    }

    /// Admits an authenticated session as the controlling viewer.
    func admit(_ session: HostSession, takeOver: Bool) -> Bool {
        lock.lock()
        let current = active
        if let current, current !== session, !takeOver {
            lock.unlock()
            return false
        }
        active = session
        pending.removeValue(forKey: session.sessionID)
        lock.unlock()
        if let current, current !== session {
            current.end(reason: "\(session.viewerName) took over this Mac.", notifyViewer: true)
        }
        updateStatus { $0.viewerName = session.viewerName }
        return true
    }

    var activeViewerName: String? {
        lock.lock()
        defer { lock.unlock() }
        return active?.viewerName
    }

    func sessionEnded(_ session: HostSession) {
        forget(session)
    }

    private func forget(_ session: HostSession) {
        lock.lock()
        pending.removeValue(forKey: session.sessionID)
        let wasActive = active === session
        if wasActive { active = nil }
        lock.unlock()
        if wasActive {
            updateStatus { $0.viewerName = nil }
            streamsDidEnd(session: session)
        }
    }

    private func route(_ batch: [(Data, SocketAddress)]) {
        lock.lock()
        let session = active
        lock.unlock()
        guard let session else { return }
        for (datagram, address) in batch where DatagramEnvelope.sessionID(of: datagram) == session.sessionID {
            session.handleDatagram(datagram, from: address)
        }
    }

    // MARK: Displays

    var virtualDisplayIDs: Set<CGDirectDisplayID> {
        lock.lock()
        defer { lock.unlock() }
        return virtualDisplay.map { [$0.displayID] } ?? []
    }

    /// Creates the virtual display if the settings call for one, and returns
    /// its visible frame for a newly opened window.
    func virtualDisplayFrameForNewStream() -> CGRect? {
        let settings = settingsStore.settings
        let wanted: Bool = switch settings.virtualDisplay {
        case .always: true
        case .never: false
        case .automatic: !VirtualDisplay.hasHiDPIDisplay
        }
        lock.lock()
        var display = virtualDisplay
        lock.unlock()
        guard wanted || display != nil else { return nil }
        if display == nil {
            display = VirtualDisplay(pointSize: CGSize(width: settings.virtualDisplayWidth,
                                                       height: settings.virtualDisplayHeight))
            guard let display else { return nil }
            lock.lock()
            virtualDisplay = display
            lock.unlock()
            display.makeExtended()
            // The window server needs a moment to settle the new arrangement.
            usleep(300_000)
        }
        guard let display else { return nil }
        return visibleFrame(containing: CGPoint(x: display.bounds.midX, y: display.bounds.midY)) ?? display.bounds
    }

    /// Removes the virtual display once nothing streams from it.
    func streamsDidEnd(session: HostSession) {
        lock.lock()
        let stillActive = active != nil && active !== session
        let display = stillActive ? nil : virtualDisplay
        if display != nil { virtualDisplay = nil }
        lock.unlock()
        if display != nil { log.info("removing virtual display") }
    }

    /// The visible frame (global top-left points) of the display containing `point`.
    func visibleFrame(containing point: CGPoint) -> CGRect? {
        let displays: [DisplaySummary]
        if Thread.isMainThread {
            displays = MainActor.assumeIsolated { HostWindows.displays(virtualDisplayIDs: []) }
        } else {
            displays = DispatchQueue.main.sync { MainActor.assumeIsolated { HostWindows.displays(virtualDisplayIDs: []) } }
        }
        return (displays.first { $0.frame.contains(point) } ?? displays.first)?.visibleFrame
    }

    @MainActor
    func icons(for summaries: [WindowSummary]) -> [String: Data] {
        var cache = iconCache
        let result = HostWindows.icons(for: summaries, cache: &cache)
        iconCache = cache
        return result
    }

    @MainActor
    func applicationList() -> (applications: [HostApplication], icons: [String: Data]) {
        let applications = HostApplications.list()
        var icons: [String: Data] = [:]
        for application in applications {
            if let cached = applicationIconCache[application.path] {
                icons[application.path] = cached
            } else if let icon = HostApplications.icon(path: application.path) {
                applicationIconCache[application.path] = icon
                icons[application.path] = icon
            }
        }
        return (applications, icons)
    }

    // MARK: Status

    private func updateStatus(_ change: (inout Status) -> Void) {
        lock.lock()
        change(&status)
        let snapshot = status
        lock.unlock()
        let callback = onStatusChange
        DispatchQueue.main.async { callback?(snapshot) }
    }

    // MARK: Permissions

    public struct Permissions: Sendable, Equatable {
        public var screenRecording: Bool
        public var accessibility: Bool
        public var postEvents: Bool
        public var allGranted: Bool { screenRecording && accessibility && postEvents }
    }

    public static var permissions: Permissions {
        Permissions(screenRecording: CGPreflightScreenCaptureAccess(), accessibility: AccessibilityPermission.isGranted,
                    postEvents: InputInjector.isAllowed)
    }

    public static func requestPermissions() {
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        if !AccessibilityPermission.isGranted { AccessibilityPermission.request() }
        if !InputInjector.isAllowed { InputInjector.requestAccess() }
    }
}
