import AnyRemoteClient
import AnyRemoteMedia
import AnyRemoteNetwork
import AnyRemoteWindowControl
import AnyRemoteWire
import AppKit
import Network
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Connection")

/// A host the viewer can connect to: this Mac, a Bonjour result, or a saved address.
struct HostTarget: Hashable, Identifiable, Sendable {
    enum Kind: Hashable, Sendable {
        case thisMac
        case discovered
        case saved
        /// Paired over Bonjour and not advertised right now.
        case offline
    }

    var id: String
    var name: String
    var kind: Kind
    var endpoint: NWEndpoint
    var hostID: String?
    var savedID: String?

    static func endpoint(fromAddress address: String) -> NWEndpoint? {
        var host = address.trimmingCharacters(in: .whitespaces)
        var port = AnyRemoteService.defaultPort
        if let colon = host.lastIndex(of: ":"), !host.hasSuffix("]"), host.filter({ $0 == ":" }).count == 1 {
            guard let parsed = UInt16(host[host.index(after: colon)...]) else { return nil }
            port = parsed
            host = String(host[..<colon])
        }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        return .hostPort(host: NWEndpoint.Host(host), port: nwPort)
    }
}

/// One live connection to a host and the windows opened from it.
@MainActor
@Observable
final class HostConnection {
    enum State: Equatable {
        case connecting
        case connected
        case failed(String)
        case disconnected
    }

    let target: HostTarget
    private(set) var state: State = .connecting
    private(set) var welcome: HostWelcome?
    private(set) var listing: WindowListing?
    /// The host's apps, loaded when the picker shows them.
    private(set) var applications: ApplicationListing?
    @ObservationIgnored private var launchRequested: Date?
    @ObservationIgnored var onLaunchedWindow: (() -> Void)?
    private(set) var isRefreshing = false
    /// Host windows currently mirrored here.
    private(set) var openWindowIDs: Set<UInt32> = []
    /// Host permissions missing as of the latest welcome or listing.
    private(set) var missingPermissions: [String] = []
    @ObservationIgnored let client: RemoteHostClient
    @ObservationIgnored private var mirrors: [UInt16: MirrorWindowController] = [:]
    /// Full desktops (whole host displays) shown here, by stream.
    @ObservationIgnored private var desktops: [UInt16: DesktopWindowController] = [:]
    /// Host displays currently shown as full desktops.
    private(set) var openDisplayIDs: Set<UInt32> = []
    @ObservationIgnored private var children: [UInt16: ChildWindowController] = [:]
    @ObservationIgnored private var pendingOpen: Set<UInt32> = []
    @ObservationIgnored private var cursorImages: [UInt32: NSCursor] = [:]
    @ObservationIgnored private(set) var currentCursor: NSCursor?
    @ObservationIgnored var onOpenedMirror: ((MirrorWindowController) -> Void)?
    @ObservationIgnored var onOpenedDesktop: ((DesktopWindowController) -> Void)?
    @ObservationIgnored var onClosed: (() -> Void)?
    @ObservationIgnored private var pasteboard: PasteboardBridge?
    @ObservationIgnored private var sharingObserver: NSObjectProtocol?
    @ObservationIgnored private var soundObserver: NSObjectProtocol?
    @ObservationIgnored private var microphoneObserver: NSObjectProtocol?
    @ObservationIgnored private var audioReportTimer: Timer?
    /// Sound statistics of the last second, while the host's sound plays here.
    @ObservationIgnored private(set) var audioReport: AudioStreamReceiver.Report?

    init(target: HostTarget, code: PairingCode) {
        self.target = target
        client = RemoteHostClient(endpoint: target.endpoint, code: code, viewerName: ComputerNameProvider.name)
        client.onEvent = { [weak self] event in self?.handle(event) }
        // The host fetches files of drags offered to it.
        let owner = WeakConnection(self)
        client.dragResolver = { dragID, itemID, reply in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let connection = owner.value else { return reply(nil) }
                    RemoteDragCoordinator.shared.resolve(connection: connection, dragID: dragID, itemID: itemID,
                                                         reply: reply)
                }
            }
        }
    }

    var hostName: String { welcome?.hostName ?? target.name }
    var openMirrors: [MirrorWindowController] { Array(mirrors.values) }
    var openDesktops: [DesktopWindowController] { Array(desktops.values) }

    /// The host's displays, main display first.
    var displays: [DisplaySummary] {
        let displays = listing?.displays ?? welcome?.displays ?? []
        return displays.sorted { ($0.isMain ?? false) && !($1.isMain ?? false) }
    }

    /// Shows a whole host display here (the main one by default). One that
    /// is already open is brought forward.
    func openDesktop(displayID: UInt32? = nil) {
        guard let displayID = displayID ?? displays.first?.displayID else { return }
        if let existing = desktops.values.first(where: { $0.displayID == displayID }) {
            NSApp.activate()
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        client.openDisplay(displayID)
    }

    /// The host display a mirrored window is on.
    func displayID(containing frame: CGRect) -> UInt32? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return (displays.first { $0.frame.contains(center) } ?? displays.first { $0.frame.intersects(frame) })?.displayID
    }

    /// Closes the mirror only; the window stays open on the host.
    func closeMirror(windowID: UInt32) {
        mirrors.values.first { $0.windowID == windowID }?.close()
    }

    func connect(takeOver: Bool = false) async throws {
        state = .connecting
        // Sent as soon as the host has let us in.
        client.setAudio(enabled: SoundSharing.isEnabled)
        client.setMicrophone(enabled: MicrophoneSharing.isEnabled)
        do {
            welcome = try await client.connect(takeOver: takeOver)
            missingPermissions = welcome?.missingPermissions ?? []
            state = .connected
            updateClipboardSharing()
            sharingObserver = NotificationCenter.default.addObserver(
                forName: ClipboardSharing.changed, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateClipboardSharing() }
            }
            soundObserver = NotificationCenter.default.addObserver(
                forName: SoundSharing.changed, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.client.setAudio(enabled: SoundSharing.isEnabled) }
            }
            microphoneObserver = NotificationCenter.default.addObserver(
                forName: MicrophoneSharing.changed, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.client.setMicrophone(enabled: MicrophoneSharing.isEnabled) }
            }
            sendTextInput()
            textInputObserver = NotificationCenter.default.addObserver(
                forName: TextInputPreferences.changed, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.sendTextInput() }
            }
            startAudioReports()
            await refresh()
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    @ObservationIgnored private var textInputObserver: NSObjectProtocol?
    @ObservationIgnored private var sentTextInput: TextInputSettings?

    /// Whose input method composes.
    private func sendTextInput() {
        guard state == .connected else { return }
        let settings = TextInputSettings(composesOnViewer: TextInputPreferences.composesOnThisMac)
        guard settings != sentTextInput else { return }
        sentTextInput = settings
        client.send(.textInput(settings))
    }

    /// Starts or stops sharing the clipboard with the host, per the setting.
    private func updateClipboardSharing() {
        let enabled = ClipboardSharing.isEnabled && state == .connected
        guard enabled != (pasteboard != nil) else { return }
        client.send(.pasteboardSharing(enabled: enabled))
        pasteboard?.stop()
        pasteboard = nil
        guard enabled else { return }
        let client = client
        let bridge = PasteboardBridge { items in client.send(.pasteboard(items: items)) }
        // What was copied here before connecting can be pasted there right away.
        bridge.start(sendingCurrent: true)
        pasteboard = bridge
    }

    private func stopClipboardSharing() {
        pasteboard?.stop()
        pasteboard = nil
        if let sharingObserver { NotificationCenter.default.removeObserver(sharingObserver) }
        sharingObserver = nil
        if let soundObserver { NotificationCenter.default.removeObserver(soundObserver) }
        soundObserver = nil
        if let microphoneObserver { NotificationCenter.default.removeObserver(microphoneObserver) }
        microphoneObserver = nil
        if let textInputObserver { NotificationCenter.default.removeObserver(textInputObserver) }
        textInputObserver = nil
        sentTextInput = nil
        audioReportTimer?.invalidate()
        audioReportTimer = nil
        audioReport = nil
    }

    private func startAudioReports() {
        let printsStatistics = ProcessInfo.processInfo.environment["ANYREMOTE_STATS_STDOUT"] == "1"
        audioReportTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.audioReport = self.client.takeAudioReport()
                if printsStatistics, let report = self.audioReport { print(report.description) }
            }
        }
    }

    func disconnect() {
        stopClipboardSharing()
        for mirror in mirrors.values { mirror.close() }
        for desktop in desktops.values { desktop.close() }
        client.disconnect()
        state = .disconnected
    }

    /// The host's apps minus AnyRemote itself and the Dock stand-ins it makes
    /// for remote apps: opening those here would only mirror AnyRemote.
    var offeredApplications: [HostApplication] {
        (applications?.applications ?? []).filter {
            !($0.bundleIdentifier ?? "").hasPrefix("com.localhost-copilot.anyremote")
        }
    }

    func loadApplications() async {
        guard state == .connected else { return }
        do {
            applications = try await client.listApplications()
        } catch {
            log.error("application list failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Opens the app on the host; its window opens here when it appears.
    func launch(_ application: HostApplication) {
        launchRequested = Date()
        client.launchApplication(path: application.path)
    }

    /// Quits the app on the host. The list follows once it has gone (an app
    /// may first ask to save, so look again a little later too).
    func quit(_ application: HostApplication, force: Bool) {
        client.quitApplication(path: application.path, force: force)
        Task {
            for delay in [1.0, 4.0] {
                try? await Task.sleep(for: .seconds(delay))
                await loadApplications()
            }
        }
    }

    func refresh() async {
        guard state == .connected, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let listing = try await client.listWindows(thumbnailMaxPixels: 480)
            self.listing = listing
            if listing.missingPermissions != missingPermissions {
                missingPermissions = listing.missingPermissions
                for mirror in mirrors.values { mirror.updateNotice() }
                for desktop in desktops.values { desktop.updateNotice() }
            }
        } catch {
            log.error("listing failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func open(_ window: WindowSummary) {
        if let existing = mirrors.values.first(where: { $0.windowID == window.windowID }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        pendingOpen.insert(window.windowID)
        client.openWindow(window.windowID)
    }

    /// Why input won't reach the host, if it can't: shown on mirrors and in the picker.
    var inputBlockedReason: String? {
        if missingPermissions.contains("accessibility") || missingPermissions.contains("post-events") {
            return String(localized: "\(hostName) hasn’t given AnyRemote Accessibility permission, so clicks and typing won’t work.")
        }
        return nil
    }

    var captureBlockedReason: String? {
        missingPermissions.contains("screen-recording") ? String(localized: "\(hostName) hasn’t given AnyRemote Screen Recording permission, so window contents can’t be shown.") : nil
    }

    // MARK: Events

    private func handle(_ event: RemoteHostClient.Event) {
        switch event {
        case .connected:
            break
        case .disconnected(let reason):
            stopClipboardSharing()
            RemoteDragCoordinator.shared.connectionClosed(self)
            let hadMirrors = !mirrors.isEmpty || !desktops.isEmpty
            for mirror in mirrors.values { mirror.hostDisconnected(reason: reason) }
            mirrors.removeAll()
            openWindowIDs.removeAll()
            let closing = desktops.values
            desktops.removeAll()
            openDisplayIDs.removeAll()
            for desktop in closing { desktop.close() }
            if hadMirrors, state != .disconnected {
                let alert = NSAlert()
                alert.messageText = String(localized: "Disconnected from “\(hostName)”")
                alert.informativeText = FriendlyText.message(reason ?? "Disconnected.")
                DispatchQueue.main.async { alert.runModal() }
            }
            children.values.forEach { $0.close() }
            children.removeAll()
            if state != .disconnected { state = .failed(reason ?? "Disconnected.") }
            missingPermissions = []
            onClosed?()
        case .streamStarted(let description):
            streamStarted(description)
        case let .streamMoved(streamID, frame, title):
            if let mirror = mirrors[streamID] {
                mirror.hostFrameChanged(frame, title: title)
                for child in children.values where child.parentStreamID == streamID { child.reposition() }
            } else if let child = children[streamID] {
                child.hostFrameChanged(frame)
            } else if let desktop = desktops[streamID] {
                desktop.hostFrameChanged(frame, title: title)
            }
        case let .streamEnded(streamID, reason):
            if let mirror = mirrors.removeValue(forKey: streamID) {
                openWindowIDs.remove(mirror.windowID)
                mirror.hostEnded(reason: reason)
            } else if streamID == 0 {
                log.notice("open failed: \(reason, privacy: .public)")
            }
            if let child = children.removeValue(forKey: streamID) { child.close() }
            if let desktop = desktops.removeValue(forKey: streamID) {
                openDisplayIDs.remove(desktop.displayID)
                desktop.hostEnded(reason: reason)
            }
        case let .resizeApplied(streamID, size):
            mirrors[streamID]?.hostResizeApplied(size)
        case .cursor(let image):
            applyCursor(image)
        case let .menuBar(streamID, applicationName, menus):
            mirrors[streamID]?.menuBarArrived(applicationName: applicationName, menus: menus)
        case let .hostReport(streamID, report):
            mirrors[streamID]?.hostReport = report
            desktops[streamID]?.hostReport = report
        case let .windowControls(streamID, controls):
            mirrors[streamID]?.controls = controls
        case let .windowStateRequest(streamID, request):
            mirrors[streamID]?.applyHostStateRequest(request)
        case let .caret(streamID, rect, font):
            mirrors[streamID]?.setCaret(rect, font: font)
            desktops[streamID]?.setCaret(rect, font: font)
        case let .pasteboard(items):
            pasteboard?.apply(items)
        case .microphone(let state):
            if state == .denied { MicrophoneSharing.explainDenial(hostName: hostName) }
        case let .hostDragBegan(streamID, manifest):
            RemoteDragCoordinator.shared.hostDragBegan(connection: self, streamID: streamID, manifest: manifest)
        }
    }

    private func streamStarted(_ description: StreamDescription) {
        switch description.role {
        case .window:
            if let existing = mirrors[description.streamID] {
                existing.window?.makeKeyAndOrderFront(nil)
                return
            }
            var requested = pendingOpen.remove(description.windowID) != nil
            if let launchRequested, Date().timeIntervalSince(launchRequested) < 25 {
                self.launchRequested = nil
                requested = true
                onLaunchedWindow?()
            }
            let mirror = MirrorWindowController(connection: self, description: description)
            mirror.onClose = { [weak self] in
                guard let self else { return }
                self.mirrors[description.streamID] = nil
                self.openWindowIDs.remove(description.windowID)
                for (id, child) in self.children where child.parentStreamID == description.streamID {
                    child.close()
                    self.children[id] = nil
                }
                self.client.detach(streamID: description.streamID)
            }
            mirrors[description.streamID] = mirror
            openWindowIDs.insert(description.windowID)
            // A window asked for from the menu bar panel opens while another
            // app is active; bring it forward, as the user is waiting for it.
            if requested { NSApp.activate() }
            mirror.showWindow(nil)
            mirror.start()
            onOpenedMirror?(mirror)
        case .display:
            if let existing = desktops[description.streamID] {
                existing.window?.makeKeyAndOrderFront(nil)
                return
            }
            let desktop = DesktopWindowController(connection: self, description: description)
            desktop.onClose = { [weak self] in
                guard let self else { return }
                self.desktops[description.streamID] = nil
                self.openDisplayIDs.remove(description.windowID)
                for id in description.tileStreamIDs ?? [] where id != description.streamID {
                    self.client.detach(streamID: id, closeOnHost: false)
                }
                self.client.detach(streamID: description.streamID)
            }
            desktops[description.streamID] = desktop
            openDisplayIDs.insert(description.windowID)
            NSApp.activate()
            desktop.showWindow(nil)
            desktop.start()
            onOpenedDesktop?(desktop)
        case .child:
            guard let parentID = description.parentStreamID, let parent = mirrors[parentID] else {
                client.send(.closeStream(streamID: description.streamID))
                return
            }
            let child = ChildWindowController(connection: self, description: description, parent: parent)
            children[description.streamID] = child
            child.start()
        }
    }

    private func applyCursor(_ image: CursorImage) {
        if let cached = cursorImages[image.seed] {
            currentCursor = cached
        } else if let png = image.png, let nsImage = NSImage(data: png) {
            nsImage.size = image.pointSize
            let cursor = NSCursor(image: nsImage, hotSpot: image.hotSpot)
            if cursorImages.count > 64 { cursorImages.removeAll() }
            cursorImages[image.seed] = cursor
            currentCursor = cursor
        }
        for mirror in mirrors.values { mirror.cursorChanged() }
        for desktop in desktops.values { desktop.cursorChanged() }
        for child in children.values { child.cursorChanged() }
    }
}

/// Lets callbacks off the main thread refer back to a connection without keeping it.
private final class WeakConnection: @unchecked Sendable {
    weak var value: HostConnection?
    init(_ value: HostConnection) { self.value = value }
}

enum ComputerNameProvider {
    static var name: String { Host.current().localizedName ?? "Mac" }
}
