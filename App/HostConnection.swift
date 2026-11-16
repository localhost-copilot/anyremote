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
    /// The connection failed because the two Macs speak different protocols.
    /// `host` is the other Mac's AnyRemote; nil when it's from before
    /// protocol 20 and doesn't say.
    private(set) var versionMismatch: VersionMismatch?
    struct VersionMismatch { var host: AppVersionInfo? }
    private(set) var welcome: HostWelcome?
    private(set) var listing: WindowListing?
    /// The host's apps, loaded when the picker shows them.
    private(set) var applications: ApplicationListing?
    // Images come after the lists they belong to, over the transfer
    // connection (see `RemoteHostClient.fetchImages`).
    /// App icons by path. Kept while connected, so each is fetched once,
    /// when a tile first shows it (`needIcon`).
    private(set) var applicationIcons: [String: Data] = [:]
    /// Icons of the listed windows' apps, by bundle identifier; kept likewise.
    private(set) var windowIcons: [String: Data] = [:]
    /// The latest thumbnail of each listed window.
    private(set) var thumbnails: [UInt32: Data] = [:]
    /// App icons asked for, or about to be.
    @ObservationIgnored private var requestedIcons: Set<String> = []
    @ObservationIgnored private var iconBatch: [String] = []
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
    /// What the other Mac's menu bar items opened, shown below their icon.
    @ObservationIgnored private var popups: [UInt16: PopupWindowController] = [:]
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
    @ObservationIgnored private var noticeObservers: [NSObjectProtocol] = []
    /// The Dock badges of the host's apps, for their Dock icons here.
    @ObservationIgnored private(set) var badges: [HostBadge] = []
    @ObservationIgnored private var audioReportTimer: Timer?
    /// Sound statistics of the last second, while the host's sound plays here.
    @ObservationIgnored private(set) var audioReport: AudioStreamReceiver.Report?

    init(target: HostTarget, code: PairingCode) {
        self.target = target
        client = RemoteHostClient(endpoint: target.endpoint, code: code, viewerName: ComputerNameProvider.name)
        // The host's virtual display for remote windows takes this size, so
        // they can grow as large as this screen and fill it in full screen.
        // The screen being worked on (its key window: where Connect was
        // clicked), which needn't be the largest or the one with the menu
        // bar: with a 4K screen in use, the largest was a portrait one.
        client.screen = (NSScreen.main ?? NSScreen.screens.first)?.viewerScreen
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

    /// The other Mac's AnyRemote, once it said: in the welcome, or when it
    /// refused another protocol.
    var hostVersion: AppVersionInfo? { welcome?.version ?? versionMismatch?.host }
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
        updateNotices()
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
            // Badges only show on the remote apps' Dock icons, so they follow that setting.
            noticeObservers = [RemoteNotifications.changed, .mirrorsChanged].map { name in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateNotices() }
                }
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
            if case .incompatible(let host)? = error as? ConnectionError { versionMismatch = VersionMismatch(host: host) }
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

    private func updateNotices() {
        client.setNotices(NoticeSubscription(notifications: RemoteNotifications.isEnabled,
                                             badges: DockProxies.isEnabled))
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
        noticeObservers.forEach { NotificationCenter.default.removeObserver($0) }
        noticeObservers = []
        if !badges.isEmpty {
            badges = []
            NotificationCenter.default.post(name: .mirrorsChanged, object: nil)
        }
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
        for attempt in 1...2 {
            guard state == .connected else { return }
            do {
                applications = try await client.listApplications()
                return
            } catch ConnectionError.timedOut where attempt == 1 {
                // A slow list, not a lost host (pings tell that): ask once more.
                log.notice("application list timed out; asking again")
            } catch {
                log.error("application list failed: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
    }

    /// A tile showing this app appeared: fetches its icon unless it's here
    /// or coming. Tiles appearing together are fetched together.
    func needIcon(forApplicationAt path: String) {
        guard applicationIcons[path] == nil, requestedIcons.insert(path).inserted else { return }
        iconBatch.append(path)
        guard iconBatch.count == 1 else { return }
        Task {
            // A screenful of tiles appears within a few frames.
            try? await Task.sleep(for: .milliseconds(30))
            let paths = iconBatch
            iconBatch.removeAll()
            let images = await client.fetchImages(paths.map { .applicationIcon(path: $0) })
            for path in paths {
                if let data = images[.applicationIcon(path: path)] {
                    applicationIcons[path] = data
                } else {
                    // Missing (or the connection dropped): a tile appearing again asks again.
                    requestedIcons.remove(path)
                }
            }
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

    /// Lists the host's windows, then fetches their apps' missing icons and
    /// (`thumbnails`) fresh thumbnails. The next refresh waits for those,
    /// so a slow network gets fewer, not more.
    func refresh(thumbnails withThumbnails: Bool = true) async {
        guard state == .connected, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let listing: WindowListing
        do {
            listing = try await client.listWindows()
        } catch {
            log.error("listing failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        self.listing = listing
        if listing.missingPermissions != missingPermissions {
            missingPermissions = listing.missingPermissions
            for mirror in mirrors.values { mirror.updateNotice() }
            for desktop in desktops.values { desktop.updateNotice() }
        }
        let ids = Set(listing.windows.map(\.windowID))
        thumbnails = thumbnails.filter { ids.contains($0.key) }
        let bundles = Set(listing.windows.compactMap(\.bundleIdentifier)).filter { windowIcons[$0] == nil }
        var wanted = bundles.sorted().map { HostImage.windowIcon(bundleIdentifier: $0) }
        if withThumbnails { wanted += listing.windows.map { .thumbnail(windowID: $0.windowID, maximumPixels: 480) } }
        for (image, data) in await client.fetchImages(wanted) {
            switch image {
            case .windowIcon(let bundle): windowIcons[bundle] = data
            case .thumbnail(let windowID, _) where self.listing?.windows.contains(where: { $0.windowID == windowID }) == true:
                thumbnails[windowID] = data
            default: break
            }
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
            let openPopups = popups.values
            popups.removeAll()
            openPopups.forEach { $0.hostEnded() }
            if state != .disconnected { state = .failed(reason ?? "Disconnected.") }
            missingPermissions = []
            onClosed?()
        case .streamStarted(let description):
            streamStarted(description)
        case let .streamMoved(streamID, frame, title, windowID):
            if let mirror = mirrors[streamID] {
                if let windowID, windowID != mirror.windowID {
                    openWindowIDs.remove(mirror.windowID)
                    openWindowIDs.insert(windowID)
                    mirror.hostWindowChanged(windowID)
                }
                mirror.hostFrameChanged(frame, title: title)
                for child in children.values where child.parentStreamID == streamID { child.reposition() }
            } else if let child = children[streamID] {
                child.hostFrameChanged(frame)
            } else if let desktop = desktops[streamID] {
                desktop.hostFrameChanged(frame, title: title)
            } else {
                popups[streamID]?.hostFrameChanged(frame)
            }
        case let .streamEnded(streamID, reason):
            popups.removeValue(forKey: streamID)?.hostEnded()
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
        case let .statusItemMenu(id, menus):
            RemoteStatusItems.shared.showMenu(menus, itemID: id, from: self)
        case .notification(let notification):
            RemoteNotifications.shared.show(notification, from: self)
        case .badges(let badges):
            guard badges != self.badges else { return }
            self.badges = badges
            NotificationCenter.default.post(name: .mirrorsChanged, object: nil)
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
            mirror.onClose = { [weak self, unowned mirror] in
                guard let self else { return }
                self.mirrors[description.streamID] = nil
                self.openWindowIDs.remove(mirror.windowID)
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
        case .popup:
            let popup = PopupWindowController(connection: self, description: description)
            popup.onClose = { [weak self] in
                self?.popups[description.streamID] = nil
                self?.client.detach(streamID: description.streamID)
            }
            popups[description.streamID] = popup
            popup.start()
            RemoteStatusItems.shared.onPopup?(popup)
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
        for popup in popups.values { popup.cursorChanged() }
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
