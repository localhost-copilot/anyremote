import AnyRemoteClient
import AnyRemoteHost
import AnyRemoteNetwork
import AnyRemoteWire
import AppKit
import Network
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Viewer")

/// Hosts the viewer can reach and the connections to them.
@MainActor
@Observable
final class ViewerModel {
    private(set) var discovered: [DiscoveredHost] = []
    private(set) var saved: [PairedHost] = []
    private(set) var connections: [String: HostConnection] = [:]
    var selection: String?
    var lastError: String?

    @ObservationIgnored let pairedStore = PairedHostStore()
    @ObservationIgnored private let browser = HostBrowser()
    @ObservationIgnored let hostService: HostService
    @ObservationIgnored var onOpenedMirror: ((MirrorWindowController) -> Void)?

    init(hostService: HostService) {
        self.hostService = hostService
        saved = pairedStore.all
        browser.onChange = { [weak self] hosts in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.discovered = hosts } }
        }
        browser.start()
    }

    var thisMacTarget: HostTarget? {
        guard let port = hostService.port, port != 0 else { return nil }
        return HostTarget(id: "this-mac", name: "This Mac", kind: .thisMac,
                          endpoint: .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!),
                          hostID: hostService.settingsStore.settings.hostID)
    }

    /// Bonjour results, minus this Mac.
    var nearbyTargets: [HostTarget] {
        let ownID = hostService.settingsStore.settings.hostID
        return discovered.filter { $0.hostID != ownID }.map { host in
            HostTarget(id: "bonjour:\(host.hostID ?? host.name)", name: host.name, kind: .discovered,
                       endpoint: host.endpoint, hostID: host.hostID,
                       savedID: host.hostID.flatMap { pairedStore.host(id: $0)?.id })
        }
    }

    /// Saved manual addresses not currently advertised over Bonjour.
    var savedTargets: [HostTarget] {
        let advertised = Set(discovered.compactMap(\.hostID))
        let ownID = hostService.settingsStore.settings.hostID
        return saved.compactMap { host in
            guard !advertised.contains(host.id), host.id != ownID, let address = host.address,
                  let endpoint = HostTarget.endpoint(fromAddress: address) else { return nil }
            return HostTarget(id: "saved:\(host.id)", name: host.name, kind: .saved, endpoint: endpoint,
                              hostID: host.id, savedID: host.id)
        }
    }

    /// Paired Bonjour hosts that aren't advertised right now.
    var offlineTargets: [HostTarget] {
        let advertised = Set(discovered.compactMap(\.hostID))
        let ownID = hostService.settingsStore.settings.hostID
        return saved.compactMap { host in
            guard !advertised.contains(host.id), host.id != ownID, host.address == nil,
                  let name = host.bonjourName else { return nil }
            return HostTarget(id: "offline:\(host.id)", name: host.name, kind: .offline,
                              endpoint: .service(name: name, type: AnyRemoteService.type, domain: "local.", interface: nil),
                              hostID: host.id, savedID: host.id)
        }
    }

    var allTargets: [HostTarget] {
        [thisMacTarget].compactMap { $0 } + nearbyTargets + savedTargets + offlineTargets
    }

    /// Controlling this Mac from itself loops input back into the mirror, so
    /// "This Mac" is only listed for development (`ANYREMOTE_LOOPBACK=1`).
    @ObservationIgnored var showsThisMac = ProcessInfo.processInfo.environment["ANYREMOTE_LOOPBACK"] == "1"

    /// Macs paired with this one, most recently used first.
    var myMacs: [HostTarget] {
        let paired = nearbyTargets.filter { $0.savedID != nil } + savedTargets + offlineTargets
        let loopback = showsThisMac ? [thisMacTarget].compactMap { $0 } : []
        return loopback + paired.sorted { (lastConnected($0) ?? .distantPast) > (lastConnected($1) ?? .distantPast) }
    }

    /// Macs advertising AnyRemote that haven't been paired yet.
    var newNearby: [HostTarget] { nearbyTargets.filter { $0.savedID == nil } }

    func lastConnected(_ target: HostTarget) -> Date? {
        (target.savedID ?? target.hostID).flatMap { pairedStore.host(id: $0)?.lastConnected }
    }

    func pairedHost(for target: HostTarget) -> PairedHost? {
        (target.savedID ?? target.hostID).flatMap { pairedStore.host(id: $0) }
    }

    /// What the picker selects when it opens: a connected Mac, else the most
    /// recently used reachable one.
    var preferredTargetID: String? {
        let candidates = myMacs + newNearby
        if let connected = candidates.first(where: { connections[$0.id]?.state == .connected }) { return connected.id }
        if let reachable = myMacs.first(where: { $0.kind != .offline }) { return reachable.id }
        return candidates.first?.id
    }

    func target(id: String) -> HostTarget? { allTargets.first { $0.id == id } }

    /// The stored pairing code for a target, if any.
    func code(for target: HostTarget) -> PairingCode? {
        if target.kind == .thisMac { return hostService.settingsStore.settings.code }
        if let id = target.savedID ?? target.hostID, let code = pairedStore.host(id: id)?.code { return code }
        return nil
    }

    func connection(for target: HostTarget) -> HostConnection? { connections[target.id] }

    /// Connects with the stored code, or `code` when pairing.
    func connect(_ target: HostTarget, code providedCode: PairingCode? = nil, takeOver: Bool = false) async {
        guard let code = providedCode ?? self.code(for: target) else { return }
        connections[target.id]?.disconnect()
        let connection = HostConnection(target: target, code: code)
        connection.onOpenedMirror = { [weak self] mirror in self?.onOpenedMirror?(mirror) }
        connections[target.id] = connection
        lastError = nil
        do {
            try await connection.connect(takeOver: takeOver)
            if target.kind != .thisMac, let welcome = connection.welcome,
               welcome.hostID != hostService.settingsStore.settings.hostID {
                let previous = target.savedID
                var address: String?
                if case let .hostPort(host, port) = target.endpoint { address = "\(host):\(port)" }
                // Keep a name the user gave this Mac.
                let name = pairedStore.host(id: welcome.hostID)?.name ?? welcome.hostName
                pairedStore.save(PairedHost(id: welcome.hostID, name: name, address: address,
                                            bonjourName: target.kind == .discovered ? target.name : nil,
                                            pairingCode: code.canonical, lastConnected: Date()),
                                 replacing: previous)
                saved = pairedStore.all
            }
        } catch {
            lastError = error.localizedDescription
            log.error("connect failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func disconnect(_ target: HostTarget) {
        connections.removeValue(forKey: target.id)?.disconnect()
    }

    func addManualHost(name: String, address: String, code: PairingCode) async -> Bool {
        guard let endpoint = HostTarget.endpoint(fromAddress: address) else {
            lastError = "Enter an address like mac-mini.local or 192.168.1.20:47800."
            return false
        }
        let provisionalID = "address:\(address)"
        pairedStore.save(PairedHost(id: provisionalID, name: name.isEmpty ? address : name, address: address,
                                    bonjourName: nil, pairingCode: code.canonical))
        saved = pairedStore.all
        let target = HostTarget(id: "saved:\(provisionalID)", name: name.isEmpty ? address : name, kind: .saved,
                                endpoint: endpoint, hostID: nil, savedID: provisionalID)
        selection = target.id
        await connect(target, code: code)
        if let connection = connections[target.id], connection.state == .connected,
           let hostID = connection.welcome?.hostID {
            // Re-key the connection under the host's stable ID.
            connections.removeValue(forKey: target.id)
            connections["saved:\(hostID)"] = connection
            selection = "saved:\(hostID)"
        }
        return true
    }

    func rename(_ target: HostTarget, to name: String) {
        guard var host = pairedHost(for: target), !name.isEmpty else { return }
        host.name = name
        pairedStore.save(host, replacing: host.id)
        saved = pairedStore.all
    }

    func forget(_ target: HostTarget) {
        disconnect(target)
        if let id = target.savedID ?? target.hostID { pairedStore.remove(id: id) }
        saved = pairedStore.all
    }

    var allMirrors: [MirrorWindowController] { connections.values.flatMap(\.openMirrors) }

    /// Called before a window opens from the picker; `keepPicker` when ⌥ was held.
    @ObservationIgnored var onPickedWindow: ((_ keepPicker: Bool) -> Void)?

    func launch(_ application: HostApplication, on connection: HostConnection, keepPicker: Bool) {
        connection.onLaunchedWindow = { [weak self] in self?.onPickedWindow?(keepPicker) }
        connection.launch(application)
    }

    func open(_ window: WindowSummary, on connection: HostConnection, keepPicker: Bool) {
        connection.open(window)
        onPickedWindow?(keepPicker)
    }
}
