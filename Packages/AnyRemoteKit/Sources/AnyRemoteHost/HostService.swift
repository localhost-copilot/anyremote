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
/// Up to `maximumViewers` viewers are connected at once, each with its own
/// session; viewers of the same display share one capture and encode (see
/// `StreamAudience`). Beyond that a viewer is refused unless it asks to take
/// over, which ends the longest-connected session.
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

    public struct Viewer: Sendable, Equatable, Identifiable {
        public var id: UInt32
        public var name: String
    }

    public struct Status: Sendable, Equatable {
        public var isListening = false
        public var port: UInt16?
        /// Connected viewers, longest-connected first.
        public var viewers: [Viewer] = []
        public var error: String?
        /// Every viewer's name in one phrase, or nil when none is connected.
        public var viewerName: String? {
            viewers.isEmpty ? nil : ListFormatter.localizedString(byJoining: viewers.map(\.name))
        }
    }

    public static let maximumViewers = 4

    /// A Mac asking to pair: show `code` until `onPairingEnded` names this `id`.
    public struct PairingPrompt: Sendable, Identifiable, Equatable {
        public var id: UInt32
        public var viewerName: String
        public var code: String
    }

    /// Wrong pairing codes tolerated in `pairingFailureWindow` before
    /// pairing pauses: with six digits, each guess is one in a million.
    static let maximumPairingFailures = 10
    static let pairingFailureWindow: TimeInterval = 15 * 60

    public let settingsStore: HostSettingsStore
    private let options: Options
    private let queue: DispatchQueue
    private let socketQueue = DispatchQueue(label: "anyremote.host.udp", qos: .userInteractive)
    private let lock = NSLock()

    private var listener: ControlListener?
    private(set) var socket: DatagramSocket?
    private var pending: [UInt32: HostSession] = [:]
    /// Admitted sessions, longest-connected first.
    private var viewers: [HostSession] = []
    private var iconCache: [String: Data] = [:]
    private var applicationIconCache: [String: Data] = [:]
    /// Virtual displays for remote windows.
    let remoteDisplays = RemoteDisplays(visibleFrame: HostService.visibleFrame(containing:))
    /// Bumped whenever the virtual display is wanted again, which cancels a
    /// pending removal.
    private var virtualDisplayGeneration = 0
    private var ownWindowIDs: Set<CGWindowID> = []
    private var status = Status()
    /// Confined to `queue`, which the sessions share.
    let microphone: HostMicrophone
    /// The host's notifications and Dock badges, for the viewers that want them.
    let notices = HostNotices()
    /// The items on the right of the menu bar, for viewers that show them.
    let statusItems = HostStatusItems()
    /// Whom each app acts for, which decides where its new windows go.
    /// Confined to `queue`.
    let appActors = AppActors()

    /// Called on the main queue.
    public var onStatusChange: (@MainActor @Sendable (Status) -> Void)?
    /// A connected viewer offered (or withdrew) the reverse pairing, with the
    /// address it connected from. Called on the main queue.
    public var onPeerPairing: (@MainActor @Sendable (PeerPairing, _ address: String?) -> Void)?
    /// A Mac asks to pair: show the code. Main queue.
    public var onPairingRequest: (@MainActor @Sendable (PairingPrompt) -> Void)?
    /// The pairing `id` ended, `paired` or not: hide its code. Main queue.
    public var onPairingEnded: (@MainActor @Sendable (_ id: UInt32, _ paired: Bool) -> Void)?
    /// The paired Macs changed (one paired). Main queue.
    public var onPairedViewersChange: (@MainActor @Sendable () -> Void)?

    // Under `lock`.
    private var activePairing: (id: UInt32, connection: ControlConnection)?
    private var pairingFailures: [Date] = []

    private var storedUpdateHandler: RemoteUpdateHandler?
    /// Updates this Mac when a paired Mac asks (see `ControlConnection`).
    /// Without one, this Mac tells other Macs it can't be updated remotely.
    public var updateHandler: RemoteUpdateHandler? {
        get { lock.withLock { storedUpdateHandler } }
        set { lock.withLock { storedUpdateHandler = newValue } }
    }

    /// This Mac's AnyRemote, as told to viewers.
    public var versionInfo: AppVersionInfo {
        AppVersionInfo(appVersion: AppVersionInfo.runningAppVersion, canUpdateRemotely: updateHandler != nil)
    }

    public init(settings: HostSettingsStore = HostSettingsStore(), options: Options = Options()) {
        self.settingsStore = settings
        self.options = options
        let queue = DispatchQueue(label: "anyremote.host", qos: .userInteractive)
        self.queue = queue
        microphone = HostMicrophone(queue: queue)
    }

    var settings: HostSettings { settingsStore.settings }

    /// Starts following whom apps act for, as far as this Mac's own input
    /// tells. Once a viewer connects; on the queue.
    func followAppActors() {
        let actors = appActors
        let queue = queue
        LocalInputMonitor.shared.onInput = { pid in queue.async { actors.note(.host, pid: pid) } }
        LocalInputMonitor.shared.start()
    }

    public var currentStatus: Status {
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    // MARK: Start / stop

    public func start() throws {
        stop()
        // After a crash, the AnyRemote Microphone may still be the default input.
        queue.async { HostMicrophone.restoreDefault() }
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
        let sessions = Array(pending.values) + viewers
        self.listener = nil
        self.socket = nil
        pending.removeAll()
        viewers.removeAll()
        lock.unlock()
        sessions.forEach { $0.end(reason: "Remote control was turned off.", notifyViewer: true) }
        listener?.cancel()
        socket?.cancel()
        updateStatus { $0 = Status() }
    }

    public var port: UInt16? { listener?.port }
    var datagramPort: UInt16 { socket?.localPort ?? 0 }

    /// Ends every viewer's session (one's, given its ID), e.g. from the host's own UI.
    public func disconnectViewer(id: UInt32? = nil) {
        lock.lock()
        let sessions = viewers.filter { id == nil || $0.sessionID == id }
        lock.unlock()
        sessions.forEach { $0.end(reason: "The host ended the session.", notifyViewer: true) }
    }

    /// Applies changed settings to the sessions under way (the sound's muting).
    /// Whether the AnyRemote Microphone driver is installed, so apps here
    /// can record from a viewer's microphone.
    public static var microphoneInstalled: Bool { HostMicrophone.isInstalled }

    /// Gives back the default input the AnyRemote Microphone replaced, if it
    /// still is the default. For quitting, when sessions can't end in time.
    public static func restoreDefaultInput() {
        HostMicrophone.restoreDefault(fallback: HostMicrophone.isActiveHere)
    }

    /// The AnyRemote Microphone was installed or removed.
    public func microphoneDriverChanged() {
        queue.async { [self] in microphone.driverChanged() }
    }

    public func settingsChanged() {
        queue.async { [self] in
            for session in sessions() { session.updateAudio() }
        }
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
            role: .host(credentials: { id in
                            let settings = store.settings
                            guard settings.isEnabled else { return .disabled }
                            return settings.credential(id: id).map(CredentialLookup.found) ?? .unknown
                        },
                        hostID: store.settings.hostID, hostName: ComputerName.current, sessionID: sessionID),
            queue: queue
        )
        control.localVersion = versionInfo
        control.updateHandler = updateHandler
        control.pairingHandler = pairingHandler(for: control)
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

    // MARK: Pairing

    private func pairingHandler(for connection: ControlConnection) -> HostPairingHandler {
        HostPairingHandler(
            begin: { [weak self, weak connection] request in
                guard let self, let connection else { return .refuse("Pairing failed.") }
                return self.beginPairing(request, connection: connection)
            },
            complete: { [weak self] request, credential in
                guard let self, let id = credential.id, let key = credential.key else { return }
                self.settingsStore.addViewer(PairedViewer(id: id, name: request.viewerName,
                                                          peerID: request.viewerID.isEmpty ? nil : request.viewerID,
                                                          key: key))
                let callback = self.onPairedViewersChange
                DispatchQueue.main.async { callback?() }
            },
            end: { [weak self] request, paired, wrongCodes in
                guard let self else { return }
                self.lock.withLock {
                    if self.activePairing?.id == request.id { self.activePairing = nil }
                    self.pairingFailures += Array(repeating: Date(), count: wrongCodes)
                }
                let callback = self.onPairingEnded
                DispatchQueue.main.async { callback?(request.id, paired) }
            })
    }

    private func beginPairing(_ request: PairingRequest, connection: ControlConnection) -> HostPairingHandler.Start {
        let now = Date()
        let refusal: String? = lock.withLock {
            pairingFailures.removeAll { now.timeIntervalSince($0) > Self.pairingFailureWindow }
            if activePairing != nil { return "Another Mac is pairing with this Mac. Try again in a moment." }
            if pairingFailures.count >= Self.maximumPairingFailures {
                return "Too many wrong pairing codes were tried. Try again in a few minutes."
            }
            activePairing = (request.id, connection)
            return nil
        }
        if let refusal { return .refuse(refusal) }
        let prompt = PairingPrompt(id: request.id, viewerName: request.viewerName, code: PairingDigits.generate())
        let callback = onPairingRequest
        DispatchQueue.main.async { callback?(prompt) }
        return .show(prompt.code)
    }

    /// Stops the pairing whose code is shown (the user cancelled it here).
    public func cancelPairing(id: UInt32) {
        let connection = lock.withLock { activePairing?.id == id ? activePairing?.connection : nil }
        connection?.cancelPairing(reason: "Pairing was cancelled on “\(ComputerName.current)”.")
    }

    /// Revokes a paired Mac's key and ends its sessions. Nil: the legacy code.
    public func revokeViewer(id: String?) {
        if let id { settingsStore.removeViewer(id: id) } else { settingsStore.removeLegacyCode() }
        endSessions(usingCredential: id)
    }

    /// Revokes the key offered to another Mac for connecting back.
    public func revokePeer(_ peerID: String) {
        guard let id = settingsStore.revokePeer(peerID) else { return }
        endSessions(usingCredential: id)
    }

    private func endSessions(usingCredential id: String?) {
        queue.async { [self] in
            for session in sessions() where session.credentialID == id {
                session.end(reason: "This Mac is no longer paired with that Mac. Pair them again.", notifyViewer: true)
            }
        }
    }

    /// Admits an authenticated session alongside the others. With every
    /// place taken, only a take-over gets in, ending the longest-connected one.
    func admit(_ session: HostSession, takeOver: Bool) -> Bool {
        lock.lock()
        var replaced: HostSession?
        if !viewers.contains(where: { $0 === session }) {
            if viewers.count >= Self.maximumViewers {
                guard takeOver else {
                    lock.unlock()
                    return false
                }
                replaced = viewers.removeFirst()
            }
            viewers.append(session)
        }
        pending.removeValue(forKey: session.sessionID)
        let list = viewers.map { Viewer(id: $0.sessionID, name: $0.viewerName) }
        lock.unlock()
        replaced?.end(reason: "\(session.viewerName) took over this Mac.", notifyViewer: true)
        updateStatus { $0.viewers = list }
        return true
    }

    /// A viewer's second connection, for dragged files, joins its session.
    /// On the queue.
    func attachTransfer(_ connection: ControlConnection, from placeholder: HostSession, toSession sessionID: UInt32,
                        token: Data) {
        lock.lock()
        pending.removeValue(forKey: placeholder.sessionID)
        let session = viewers.first { $0.sessionID == sessionID }
        lock.unlock()
        guard let session else {
            connection.close()
            return
        }
        session.adoptTransfer(connection, token: token)
    }

    /// Everyone connected, for a refused viewer.
    var activeViewerName: String? {
        lock.lock()
        defer { lock.unlock() }
        return viewers.isEmpty ? nil : viewers.map(\.viewerName).joined(separator: ", ")
    }

    /// The other admitted sessions. Sessions share the service's queue, so
    /// on it their queue-confined state may be read.
    func sessions(except session: HostSession? = nil) -> [HostSession] {
        lock.lock()
        defer { lock.unlock() }
        return viewers.filter { $0 !== session }
    }

    func sessionEnded(_ session: HostSession) {
        forget(session)
        microphone.sessionEnded(session)
        notices.remove(session)
    }

    private func forget(_ session: HostSession) {
        lock.lock()
        pending.removeValue(forKey: session.sessionID)
        let wasActive = viewers.contains { $0 === session }
        viewers.removeAll { $0 === session }
        let list = viewers.map { Viewer(id: $0.sessionID, name: $0.viewerName) }
        lock.unlock()
        if wasActive {
            updateStatus { $0.viewers = list }
            streamsDidEnd(session: session)
        }
    }

    private func route(_ batch: [(Data, SocketAddress)]) {
        lock.lock()
        let sessions = viewers
        lock.unlock()
        guard !sessions.isEmpty else { return }
        for (datagram, address) in batch {
            let id = DatagramEnvelope.sessionID(of: datagram)
            sessions.first { $0.sessionID == id }?.handleDatagram(datagram, from: address)
        }
    }

    // MARK: Displays

    /// The virtual displays remote windows are on. Any thread.
    var virtualDisplayIDs: Set<CGDirectDisplayID> { remoteDisplays.displayIDs }

    /// Where a window shown on the viewer's `screen` goes, as the settings
    /// say (see `RemoteDisplays`): a virtual display (made if needed) and
    /// the frame a window there may take; nil to stay on this Mac's
    /// screens. The display refreshes `refreshRate` times a second. On the queue.
    func remoteWindowTarget(for screen: ViewerScreen?, refreshRate: Int) -> (displayID: CGDirectDisplayID, frame: CGRect)? {
        let settings = settingsStore.settings
        let fixed = CGSize(width: settings.virtualDisplayWidth, height: settings.virtualDisplayHeight)
        lock.lock()
        virtualDisplayGeneration += 1
        lock.unlock()
        guard settings.virtualDisplay != .never else { return nil }
        // A viewer on this Mac itself (loopback) sees these displays as its
        // own screens; one of them isn't a screen to make a display for.
        let screen = screen.flatMap { remoteDisplays.displayIDs.contains($0.id) ? nil : $0 }
        let target = remoteDisplays.target(for: screen, fallbackSize: fixed, refreshRate: refreshRate)
        if target != nil { watchDisplayArrangement() }
        return target
    }

    /// The viewer's frame rate changed: the displays its windows are on
    /// follow. On the queue.
    func setRemoteDisplayRefreshRate(_ refreshRate: Int) {
        remoteDisplays.setRefreshRate(refreshRate)
    }

    /// The frame a window may take on the virtual display `displayID`.
    func remoteWindowFrame(on displayID: CGDirectDisplayID) -> CGRect? {
        remoteDisplays.frame(of: displayID)
    }

    // MARK: Keeping the virtual displays in place

    private var watchingArrangement = false
    private var arrangementCheckPending = false

    /// macOS rearranges displays when one comes or goes, wakes or changes
    /// mode, and may then mirror a virtual display with this Mac's screen
    /// again (seen when another display appeared): its windows land on this
    /// Mac's screen and the virtual display shows a copy of it. After every
    /// change the displays are put back, and the remote windows with them.
    private func watchDisplayArrangement() {
        lock.lock()
        let already = watchingArrangement
        watchingArrangement = true
        lock.unlock()
        guard !already else { return }
        CGDisplayRegisterReconfigurationCallback({ _, flags, context in
            guard !flags.contains(.beginConfigurationFlag), let context else { return }
            Unmanaged<HostService>.fromOpaque(context).takeUnretainedValue().arrangementChanged()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func arrangementChanged() {
        queue.async { [self] in
            guard !arrangementCheckPending, !remoteDisplays.isEmpty else { return }
            arrangementCheckPending = true
            // One look once the changes settle (one change sends several).
            queue.asyncAfter(deadline: .now() + 0.5) { [self] in
                arrangementCheckPending = false
                let restored = remoteDisplays.restoreArrangement()
                guard !restored.isEmpty else { return }
                for session in sessions() { session.returnWindows(to: restored) }
            }
        }
    }

    /// Removes the virtual displays once no viewer is in control any more,
    /// after a moment, so windows that were full screen there first leave
    /// their Space and move back. They stay while a viewer stays connected
    /// without windows: making them again would shift this Mac's windows
    /// again (see `RemoteDisplays`). On the queue.
    func streamsDidEnd(session: HostSession) {
        guard sessions().isEmpty, !remoteDisplays.isEmpty else { return }
        lock.lock()
        let generation = virtualDisplayGeneration
        lock.unlock()
        queue.asyncAfter(deadline: .now() + 3) { [self] in
            guard sessions().isEmpty else { return }
            lock.lock()
            let current = generation == virtualDisplayGeneration
            lock.unlock()
            if current { remoteDisplays.removeAll() }
        }
    }

    /// The visible frame (global top-left points) of the display containing `point`.
    func visibleFrame(containing point: CGPoint) -> CGRect? { Self.visibleFrame(containing: point) }

    static func visibleFrame(containing point: CGPoint) -> CGRect? {
        let displays: [DisplaySummary]
        if Thread.isMainThread {
            displays = MainActor.assumeIsolated { HostWindows.displays(virtualDisplayIDs: []) }
        } else {
            displays = DispatchQueue.main.sync { MainActor.assumeIsolated { HostWindows.displays(virtualDisplayIDs: []) } }
        }
        return (displays.first { $0.frame.contains(point) } ?? displays.first)?.visibleFrame
    }

    /// The icon of a running app, for windows of it in the viewer's list.
    @MainActor
    func windowIcon(bundleIdentifier: String) -> Data? {
        if let cached = iconCache[bundleIdentifier] { return cached }
        guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first,
              let icon = HostWindows.icon(of: application) else { return nil }
        iconCache[bundleIdentifier] = icon
        return icon
    }

    /// The icon of an app on disk, for the viewer's list of apps.
    @MainActor
    func applicationIcon(path: String) -> Data? {
        // Apps only: the viewer has no business with other files' icons.
        guard path.hasSuffix(".app") else { return nil }
        if let cached = applicationIconCache[path] { return cached }
        guard let icon = HostApplications.icon(path: path) else { return nil }
        applicationIconCache[path] = icon
        return icon
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
