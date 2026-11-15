import AnyRemoteClient
import AnyRemoteMedia
import AnyRemoteNetwork
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
    @ObservationIgnored private var children: [UInt16: ChildWindowController] = [:]
    @ObservationIgnored private var pendingOpen: Set<UInt32> = []
    @ObservationIgnored private var cursorImages: [UInt32: NSCursor] = [:]
    @ObservationIgnored private(set) var currentCursor: NSCursor?
    @ObservationIgnored var onOpenedMirror: ((MirrorWindowController) -> Void)?
    @ObservationIgnored var onClosed: (() -> Void)?

    init(target: HostTarget, code: PairingCode) {
        self.target = target
        client = RemoteHostClient(endpoint: target.endpoint, code: code, viewerName: ComputerNameProvider.name)
        client.onEvent = { [weak self] event in self?.handle(event) }
    }

    var hostName: String { welcome?.hostName ?? target.name }
    var openMirrors: [MirrorWindowController] { Array(mirrors.values) }

    /// Closes the mirror only; the window stays open on the host.
    func closeMirror(windowID: UInt32) {
        mirrors.values.first { $0.windowID == windowID }?.close()
    }

    func connect(takeOver: Bool = false) async throws {
        state = .connecting
        do {
            welcome = try await client.connect(takeOver: takeOver)
            missingPermissions = welcome?.missingPermissions ?? []
            state = .connected
            await refresh()
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func disconnect() {
        for mirror in mirrors.values { mirror.close() }
        client.disconnect()
        state = .disconnected
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

    /// Host address usable outside AnyRemote (e.g. `vnc://`).
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

    var hostAddressForURL: String? {
        if case let .hostPort(host, _) = target.endpoint {
            let text = "\(host)"
            return text.contains(":") ? "[\(text)]" : text
        }
        if case let .service(name, _, _, _) = target.endpoint {
            return name.replacingOccurrences(of: " ", with: "-") + ".local"
        }
        return nil
    }

    // MARK: Events

    private func handle(_ event: RemoteHostClient.Event) {
        switch event {
        case .connected:
            break
        case .disconnected(let reason):
            let hadMirrors = !mirrors.isEmpty
            for mirror in mirrors.values { mirror.hostDisconnected(reason: reason) }
            mirrors.removeAll()
            openWindowIDs.removeAll()
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
            }
        case let .streamEnded(streamID, reason):
            if let mirror = mirrors.removeValue(forKey: streamID) {
                openWindowIDs.remove(mirror.windowID)
                mirror.hostEnded(reason: reason)
            } else if streamID == 0 {
                log.notice("open failed: \(reason, privacy: .public)")
            }
            if let child = children.removeValue(forKey: streamID) { child.close() }
        case let .resizeApplied(streamID, size):
            mirrors[streamID]?.hostResizeApplied(size)
        case .cursor(let image):
            applyCursor(image)
        case let .menuBar(streamID, applicationName, menus):
            mirrors[streamID]?.menuBarArrived(applicationName: applicationName, menus: menus)
        case let .hostReport(streamID, report):
            mirrors[streamID]?.hostReport = report
        case let .windowControls(streamID, controls):
            mirrors[streamID]?.controls = controls
        case let .windowStateRequest(streamID, request):
            mirrors[streamID]?.applyHostStateRequest(request)
        }
    }

    private func streamStarted(_ description: StreamDescription) {
        switch description.role {
        case .window:
            if let existing = mirrors[description.streamID] {
                existing.window?.makeKeyAndOrderFront(nil)
                return
            }
            pendingOpen.remove(description.windowID)
            if let launchRequested, Date().timeIntervalSince(launchRequested) < 25 {
                self.launchRequested = nil
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
            mirror.showWindow(nil)
            mirror.start()
            onOpenedMirror?(mirror)
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
        for child in children.values { child.cursorChanged() }
    }
}

enum ComputerNameProvider {
    static var name: String { Host.current().localizedName ?? "Mac" }
}
