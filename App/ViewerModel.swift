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
    let tailnet: TailnetService
    @ObservationIgnored var onOpenedMirror: ((MirrorWindowController) -> Void)?
    @ObservationIgnored var onOpenedDesktop: ((DesktopWindowController) -> Void)?

    init(hostService: HostService, tailnet: TailnetService) {
        self.hostService = hostService
        self.tailnet = tailnet
        saved = pairedStore.all
        browser.onChange = { [weak self] hosts in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.discovered = hosts } }
        }
        browser.start()
        hostService.onPeerPairing = { [weak self] pairing, address in self?.receive(pairing, address: address) }
        tailnet.onFoundMacs = { [weak self] peers in self?.identifyPairedMacs(on: peers) }
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

    /// One target per paired Mac ("mac:<its ID>"), however it's reached
    /// right now: nearby over Bonjour, at the address set by hand, on the
    /// tailnet, or offline. The ID stays when the way changes, so a
    /// connection outlives a move between networks.
    var pairedTargets: [HostTarget] {
        let ownID = hostService.settingsStore.settings.hostID
        var nearby: [String: DiscoveredHost] = [:]
        for host in discovered { if let id = host.hostID, nearby[id] == nil { nearby[id] = host } }
        return saved.compactMap { host in
            guard host.id != ownID else { return nil }
            let id = "mac:\(host.id)"
            if let found = nearby[host.id] {
                return HostTarget(id: id, name: host.name, kind: .discovered, endpoint: found.endpoint,
                                  hostID: host.id, savedID: host.id)
            }
            if let address = host.address, let endpoint = HostTarget.endpoint(fromAddress: address) {
                var target = HostTarget(id: id, name: host.name, kind: .saved, endpoint: endpoint,
                                        hostID: host.id, savedID: host.id)
                // A tailnet address goes through the embedded node unless the Tailscale app routes it.
                if case let .hostPort(ip, _) = endpoint, TailnetAddress.isTailnet("\(ip)") {
                    target.viaTailnetNode = tailnet.routesThroughNode
                }
                return target
            }
            if let address = host.tailnetAddress,
               var target = tailnetTarget(address: address, id: id, name: host.name, hostID: host.id, savedID: host.id) {
                if !tailnet.isReachable { target.kind = .offline }
                return target
            }
            guard let name = host.bonjourName else { return nil }
            return HostTarget(id: id, name: host.name, kind: .offline,
                              endpoint: .service(name: name, type: AnyRemoteService.type, domain: "local.", interface: nil),
                              hostID: host.id, savedID: host.id)
        }
    }

    /// Macs running AnyRemote that the embedded node found on the tailnet
    /// and that aren't paired here yet.
    var tailnetTargets: [HostTarget] {
        let known = Set(saved.flatMap { [$0.tailnetAddress, $0.address.flatMap(Self.host(ofAddress:))].compactMap { $0 } })
        return tailnet.anyRemoteMacs.compactMap { peer in
            guard let address = peer.preferredAddress, !known.contains(address) else { return nil }
            return tailnetTarget(address: address, id: "tailnet:\(address)", name: peer.name, hostID: nil, savedID: nil)
        }
    }

    private func tailnetTarget(address: String, id: String, name: String, hostID: String?,
                               savedID: String?) -> HostTarget? {
        guard let endpoint = HostTarget.endpoint(fromAddress: address.contains(":") ? "[\(address)]" : address)
        else { return nil }
        var target = HostTarget(id: id, name: name, kind: .tailnet, endpoint: endpoint, hostID: hostID, savedID: savedID)
        target.viaTailnetNode = tailnet.routesThroughNode
        return target
    }

    private static func host(ofAddress address: String) -> String? {
        guard case let .hostPort(host, _)? = HostTarget.endpoint(fromAddress: address) else { return nil }
        return "\(host)"
    }

    var allTargets: [HostTarget] {
        [thisMacTarget].compactMap { $0 } + pairedTargets + newNearby + tailnetTargets
    }

    /// How a target is reached: this Mac's network, or the embedded node.
    func route(for target: HostTarget) -> HostRoute {
        if target.viaTailnetNode, let sockets = tailnet.sockets, case let .hostPort(host, port) = target.endpoint {
            return .tailnet(sockets, host: "\(host)", port: port.rawValue)
        }
        return .network(target.endpoint)
    }

    /// The ways to a paired Mac, in order of preference: Bonjour or the
    /// address set by hand, its addresses on local networks (as it said,
    /// and where Tailscale reaches it directly: a routed subnet Bonjour
    /// doesn't cross), then its tailnet address. `connect` takes the first
    /// that answers (`RouteProbe`), so the LAN wins whenever it works.
    func routes(for target: HostTarget) -> [HostRoute] {
        guard target.kind != .thisMac, let host = pairedHost(for: target) else { return [route(for: target)] }
        var targets: [HostTarget] = target.kind == .tailnet ? [] : [target]
        var port = AnyRemoteService.defaultPort
        if case let .hostPort(_, found) = target.endpoint { port = found.rawValue }
        let own = Set(LocalAddresses.current())
        let seenByTailscale = host.tailnetAddress.flatMap { tailnet.peer(at: $0)?.lanAddress }
        for address in (host.localAddresses ?? []) + [seenByTailscale].compactMap({ $0 }) where !own.contains(address) {
            guard let endpoint = HostTarget.endpoint(fromAddress: "\(address):\(port)") else { continue }
            targets.append(HostTarget(id: target.id, name: target.name, kind: .saved, endpoint: endpoint,
                                      hostID: target.hostID, savedID: target.savedID))
        }
        if tailnet.isReachable, let address = host.tailnetAddress,
           let viaTailnet = tailnetTarget(address: address, id: target.id, name: target.name,
                                          hostID: target.hostID, savedID: target.savedID) {
            targets.append(viaTailnet)
        } else if target.kind == .tailnet {
            targets.append(target)
        }
        var seen = Set<NWEndpoint>()
        targets = targets.filter { seen.insert($0.endpoint).inserted }
        let overTailnet: (HostTarget) -> Bool = { candidate in
            if candidate.viaTailnetNode { return true }
            if case let .hostPort(ip, _) = candidate.endpoint { return TailnetAddress.isTailnet("\(ip)") }
            return false
        }
        switch host.routePreference ?? .automatic {
        case .automatic: break
        case .localOnly: targets = targets.filter { !overTailnet($0) }
        // Without a tailnet address yet, the other ways are all there is.
        case .tailnetOnly where targets.contains(where: overTailnet): targets = targets.filter(overTailnet)
        case .tailnetOnly: break
        }
        return (targets.isEmpty ? [target] : targets).map(route(for:))
    }

    func setRoutePreference(_ target: HostTarget, _ preference: RoutePreference) {
        guard var host = pairedHost(for: target) else { return }
        host.routePreference = preference == .automatic ? nil : preference
        pairedStore.save(host, replacing: host.id)
        saved = pairedStore.all
    }

    /// The Mac whose information the picker shows (Info…, ⌘I, or the menu bar panel).
    var infoTargetID: String?

    /// Controlling this Mac from itself loops input back into the mirror, so
    /// "This Mac" is only listed for development (`ANYREMOTE_LOOPBACK=1`).
    @ObservationIgnored var showsThisMac = ProcessInfo.processInfo.environment["ANYREMOTE_LOOPBACK"] == "1"

    /// Macs paired with this one, most recently used first.
    var myMacs: [HostTarget] {
        let paired = pairedTargets
        let loopback = showsThisMac ? [thisMacTarget].compactMap { $0 } : []
        return loopback + paired.sorted { (lastConnected($0) ?? .distantPast) > (lastConnected($1) ?? .distantPast) }
    }

    /// Macs advertising AnyRemote that haven't been paired yet.
    var newNearby: [HostTarget] { nearbyTargets.filter { $0.savedID == nil } }

    /// Unpaired Macs on the tailnet not seen nearby already.
    var newOnTailnet: [HostTarget] {
        let nearby = Set(newNearby.compactMap(\.hostID))
        return tailnetTargets.filter { $0.hostID.map { !nearby.contains($0) } ?? true }
    }

    func lastConnected(_ target: HostTarget) -> Date? {
        (target.savedID ?? target.hostID).flatMap { pairedStore.host(id: $0)?.lastConnected }
    }

    func pairedHost(for target: HostTarget) -> PairedHost? {
        (target.savedID ?? target.hostID).flatMap { pairedStore.host(id: $0) }
    }

    /// What the picker selects when it opens: a connected Mac, else the most
    /// recently used reachable one.
    var preferredTargetID: String? {
        let candidates = myMacs + newNearby + newOnTailnet
        if let connected = candidates.first(where: { connections[$0.id]?.state == .connected }) { return connected.id }
        if let reachable = myMacs.first(where: { $0.kind != .offline }) { return reachable.id }
        return candidates.first?.id
    }

    func target(id: String) -> HostTarget? { allTargets.first { $0.id == id } }

    /// The key this Mac reaches a target with, once paired.
    func credential(for target: HostTarget) -> PairingCredential? {
        if target.kind == .thisMac { return hostService.settingsStore.loopbackCredential }
        if let id = target.savedID ?? target.hostID, let credential = pairedStore.host(id: id)?.credential {
            return credential
        }
        return nil
    }

    func isPaired(_ target: HostTarget) -> Bool { credential(for: target) != nil }

    func connection(for target: HostTarget) -> HostConnection? { connections[target.id] }

    /// Keeps a paired Mac's tailnet address as found, or as its key proved.
    private func learnTailnetAddress(_ address: String, for hostID: String) {
        guard var host = pairedStore.host(id: hostID), host.tailnetAddress != address else { return }
        host.tailnetAddress = address
        pairedStore.save(host, replacing: host.id)
        saved = pairedStore.all
    }

    @ObservationIgnored private var identityTried: Set<String> = []
    @ObservationIgnored private var identifying = false

    /// The node found AnyRemote at addresses no paired Mac is known by. A
    /// paired Mac that never said its tailnet address (an AnyRemote before
    /// 0.32, or one that joined the tailnet after this Mac last reached it)
    /// may be one of them: its key tells, without a session or a new pairing
    /// (`HostIdentityProbe`). Likely names first; each address and Mac is
    /// tried once per launch.
    func identifyPairedMacs(on peers: [TailnetStatus.Peer]) {
        guard !identifying else { return }
        let ownID = hostService.settingsStore.settings.hostID
        let known = Set(saved.compactMap(\.tailnetAddress))
        let unknown = saved.filter { $0.tailnetAddress == nil && $0.credential != nil && $0.id != ownID }
        let candidates = peers.filter { $0.preferredAddress.map { !known.contains($0) } ?? false }
        guard !unknown.isEmpty, !candidates.isEmpty else { return }
        identifying = true
        Task { @MainActor in
            defer { identifying = false }
            for peer in candidates {
                guard let address = peer.preferredAddress,
                      let probe = tailnetTarget(address: address, id: "probe", name: peer.name, hostID: nil, savedID: nil)
                else { continue }
                let likely: (PairedHost) -> Bool = { host in
                    [host.name, host.bonjourName].compactMap { $0 }.contains { peer.hostName.hasPrefix($0) }
                }
                let ordered = unknown.filter(likely) + unknown.filter { !likely($0) }
                for host in ordered where pairedStore.host(id: host.id)?.tailnetAddress == nil {
                    guard let credential = host.credential, identityTried.insert("\(address) \(host.id)").inserted
                    else { continue }
                    let id = await HostIdentityProbe.hostID(at: route(for: probe), credential: credential,
                                                            viewerName: ComputerNameProvider.name)
                    if id == host.id {
                        log.notice("\(host.name, privacy: .public) is on the tailnet at \(address, privacy: .public)")
                        learnTailnetAddress(address, for: host.id)
                        break
                    }
                }
            }
        }
    }

    /// The connection of the Mac selected in the picker.
    var selectedConnection: HostConnection? { selection.flatMap { connections[$0] } }

    /// Connects with the stored key, or `credential` (a development launch
    /// given a code); `sharesBack` says whether that Mac may also control
    /// this one.
    func connect(_ target: HostTarget, credential providedCredential: PairingCredential? = nil,
                 sharesBack: Bool? = nil, takeOver: Bool = false) async {
        guard let credential = providedCredential ?? self.credential(for: target) else { return }
        connections[target.id]?.disconnect()
        lastError = nil
        let routes = routes(for: target)
        var order = Array(routes.indices)
        if routes.count > 1, let best = await RouteProbe.preferred(routes) {
            order.removeAll { $0 == best }
            order.insert(best, at: 0)
        }
        let expectedID = target.savedID ?? target.hostID
        for (position, index) in order.enumerated() {
            let route = routes[index]
            let connection = HostConnection(target: target, route: route, credential: credential)
            connection.tailnet = tailnet
            connection.onOpenedMirror = { [weak self] mirror in self?.onOpenedMirror?(mirror) }
            connection.onOpenedDesktop = { [weak self] desktop in self?.onOpenedDesktop?(desktop) }
            connections[target.id] = connection
            connection.client.setMaximumBitRate(pairedHost(for: target)?.maximumBitRate)
            connection.client.setFrameRate(pairedHost(for: target)?.frameRate)
            do {
                try await connection.connect(takeOver: takeOver)
                if target.kind != .thisMac, let welcome = connection.welcome,
                   welcome.hostID != hostService.settingsStore.settings.hostID {
                    let host = remember(target, hostID: welcome.hostID, hostName: welcome.hostName,
                                        credential: credential, sharesBack: sharesBack, connected: true,
                                        tailnetAddress: welcome.tailnetAddresses?.first,
                                        localAddresses: welcome.localAddresses)
                    connection.savedName = host.name
                    offerPairing(to: host, over: connection)
                }
                return
            } catch {
                // Not there this way: nothing answered, or another Mac did (an
                // address of one network can be another Mac's on another).
                let reachedIt = connection.client.reachedHostID.map { expectedID == nil || $0 == expectedID } ?? false
                if position < order.count - 1, !reachedIt, connections[target.id] === connection {
                    log.notice("\(target.name, privacy: .public) not reached by \(route.isTailnet ? "the tailnet node" : "\(route.endpoint)", privacy: .public); trying the next way")
                    continue
                }
                lastError = error.localizedDescription
                log.error("connect failed: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
    }

    /// Saves a Mac under its stable ID with the key to reach it, keeping a
    /// name the user gave it and its settings, and replacing the entry it
    /// had before its ID was known (one added by address).
    @discardableResult
    private func remember(_ target: HostTarget, hostID: String, hostName: String, credential: PairingCredential,
                          sharesBack: Bool?, connected: Bool, tailnetAddress: String? = nil,
                          localAddresses: [String]? = nil) -> PairedHost {
        let previous = target.savedID
        var address: String?
        // Only an address set by hand is kept as one; a tailnet address is
        // kept as the Mac's tailnet address, used whenever it isn't nearby.
        if target.kind == .saved, case let .hostPort(host, port) = target.endpoint {
            let host = "\(host)"
            address = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        }
        var foundOnTailnet: String?
        if target.kind == .tailnet || target.kind == .offline, case let .hostPort(host, _) = target.endpoint,
           TailnetAddress.isTailnet("\(host)") { foundOnTailnet = "\(host)" }
        let existing = pairedStore.host(id: hostID) ?? previous.flatMap { pairedStore.host(id: $0) }
        // The service's own name: a paired Mac's target shows the name given it here.
        var serviceName: String?
        if target.kind == .discovered {
            if case let .service(name, _, _, _) = target.endpoint { serviceName = name } else { serviceName = target.name }
        }
        let host = PairedHost(id: hostID, name: existing?.name ?? hostName,
                              // An address set by hand stays when the Mac is reached another way;
                              // only Bonjour takes its place, as before.
                              address: address ?? (target.kind == .discovered ? nil : existing?.address),
                              bonjourName: serviceName ?? existing?.bonjourName,
                              credential: credential, lastConnected: connected ? Date() : existing?.lastConnected,
                              fromPeer: existing?.fromPeer ?? false,
                              sharesBack: sharesBack ?? existing?.sharesBack ?? true,
                              maximumBitRate: existing?.maximumBitRate, frameRate: existing?.frameRate,
                              tailnetAddress: tailnetAddress ?? foundOnTailnet ?? existing?.tailnetAddress,
                              localAddresses: localAddresses ?? existing?.localAddresses)
        pairedStore.save(host, replacing: previous)
        saved = pairedStore.all
        return host
    }

    /// Pairs with a Mac: it shows six digits, which `codes` is asked for
    /// (again after a wrong one). Then connects with the new key. Returns
    /// the Mac's ID once paired.
    @discardableResult
    func pair(_ target: HostTarget, sharesBack: Bool, flow: PairingFlow) async -> String? {
        let client = HostPairingClient(route: route(for: target), viewerName: ComputerNameProvider.name,
                                       viewerID: hostService.settingsStore.settings.hostID)
        flow.begin(client)
        do {
            let paired = try await client.run()
            remember(target, hostID: paired.hostID, hostName: paired.hostName, credential: paired.credential,
                     sharesBack: sharesBack, connected: false)
            flow.finish(nil)
            // A Mac added by address is now saved under its ID.
            let current = allTargets.first { $0.savedID == paired.hostID } ?? target
            if current.id != target.id, selection == target.id { selection = current.id }
            await connect(current, sharesBack: sharesBack)
            return paired.hostID
        } catch {
            log.error("pairing with \(target.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            flow.finish(error.localizedDescription)
            return nil
        }
    }

    /// Tells a connected Mac how to connect back here (a key made for it
    /// alone), or withdraws that and revokes the key. Sent on every
    /// connection.
    private func offerPairing(to host: PairedHost, over connection: HostConnection) {
        let store = hostService.settingsStore
        let credential: PairingCredential?
        if host.sharesBack {
            credential = store.credential(forPeer: host.id, name: connection.welcome?.hostName ?? host.name)
        } else {
            hostService.revokePeer(host.id)
            credential = nil
        }
        connection.client.send(.peerPairing(PeerPairing(
            hostID: store.settings.hostID, name: ComputerName.current, credential: credential,
            port: hostService.port, usesAddress: host.address != nil)))
    }

    func sharesBack(_ target: HostTarget) -> Bool { pairedHost(for: target)?.sharesBack ?? true }

    func setSharesBack(_ target: HostTarget, _ shares: Bool) {
        guard var host = pairedHost(for: target) else { return }
        host.sharesBack = shares
        pairedStore.save(host, replacing: host.id)
        saved = pairedStore.all
        if let connection = connections[target.id], connection.state == .connected {
            offerPairing(to: host, over: connection)
        }
    }

    func maximumBitRate(_ target: HostTarget) -> Int? { pairedHost(for: target)?.maximumBitRate }

    /// Caps the video from that Mac (nil: automatic), on the open windows too.
    func setMaximumBitRate(_ target: HostTarget, _ bitRate: Int?) {
        guard var host = pairedHost(for: target), host.maximumBitRate != bitRate else { return }
        host.maximumBitRate = bitRate
        pairedStore.save(host, replacing: host.id)
        saved = pairedStore.all
        connections[target.id]?.client.setMaximumBitRate(bitRate)
    }

    /// Frames a second to show that Mac's windows at (nil: 60).
    func frameRate(_ target: HostTarget) -> Int? { pairedHost(for: target)?.frameRate }

    /// On the open windows too.
    func setFrameRate(_ target: HostTarget, _ rate: Int?) {
        let rate = rate == FrameRate.standard ? nil : rate
        guard var host = pairedHost(for: target), host.frameRate != rate else { return }
        host.frameRate = rate
        pairedStore.save(host, replacing: host.id)
        saved = pairedStore.all
        connections[target.id]?.client.setFrameRate(rate)
    }

    /// Another Mac paired with this one and offered the way back.
    private func receive(_ pairing: PeerPairing, address: String?) {
        let outcome = pairedStore.apply(pairing, address: address, ownID: hostService.settingsStore.settings.hostID)
        log.notice("peer pairing from \(pairing.name, privacy: .public): \(String(describing: outcome), privacy: .public)")
        guard outcome != .unchanged else { return }
        saved = pairedStore.all
        if outcome == .added { PeerPairingNotice.show(name: pairing.name) }
    }

    func disconnect(_ target: HostTarget) {
        connections.removeValue(forKey: target.id)?.disconnect()
    }

    // MARK: Updating other Macs

    enum RemoteUpdateState: Equatable {
        /// Waiting for the other Mac to download and check the update.
        case asking
        case relaunching(version: String)
        case failed(String)
    }

    /// Updates of other Macs asked for from here, by target.
    private(set) var remoteUpdates: [String: RemoteUpdateState] = [:]

    /// Asks the Mac to update its AnyRemote, then reconnects once it is back.
    func updateHost(_ target: HostTarget, credential providedCredential: PairingCredential? = nil) async {
        guard let credential = providedCredential ?? credential(for: target), remoteUpdates[target.id] != .asking
        else { return }
        remoteUpdates[target.id] = .asking
        let version: String
        do {
            version = try await RemoteUpdateRequest.send(to: route(for: target), credential: credential,
                                                         viewerName: ComputerNameProvider.name)
        } catch {
            log.error("updating \(target.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            remoteUpdates[target.id] = .failed(FriendlyText.message(error.localizedDescription))
            return
        }
        log.notice("\(target.name, privacy: .public) is relaunching with \(version, privacy: .public)")
        remoteUpdates[target.id] = .relaunching(version: version)
        // Its windows here close as it quits; the session ends either way.
        connections.removeValue(forKey: target.id)?.disconnect()
        try? await Task.sleep(for: .seconds(5))
        for _ in 0..<36 {
            await connect(target, credential: providedCredential)
            let connection = connections[target.id]
            if connection?.state == .connected { break }
            // Back, but still on another protocol: say so instead of retrying.
            if let host = connection?.versionMismatch?.host, host.appVersion == version { break }
            try? await Task.sleep(for: .seconds(5))
        }
        if connections[target.id]?.state == .connected || connections[target.id]?.versionMismatch != nil {
            remoteUpdates[target.id] = nil
        } else {
            remoteUpdates[target.id] = .failed(String(localized: "“\(target.name)” didn’t come back after updating. Check that AnyRemote is running on it."))
        }
    }

    func dismissRemoteUpdate(_ target: HostTarget) { remoteUpdates[target.id] = nil }

    /// A connected Mac on the same protocol with an older AnyRemote that
    /// can update itself.
    func canUpdate(_ target: HostTarget) -> Bool {
        guard target.kind != .thisMac, let connection = connections[target.id], connection.state == .connected,
              let host = connection.hostVersion, host.canUpdateRemotely,
              let theirs = AppVersion(host.appVersion), let mine = AppVersion(AppVersionInfo.runningAppVersion)
        else { return false }
        return theirs < mine
    }

    /// Saves a Mac by address. It then needs pairing, which its pane offers.
    func addManualHost(name: String, address: String) -> Bool {
        guard HostTarget.endpoint(fromAddress: address) != nil else {
            lastError = String(localized: "Enter an address like mac-mini.local or 192.168.1.20:47800.")
            return false
        }
        let provisionalID = "address:\(address)"
        pairedStore.save(PairedHost(id: provisionalID, name: name.isEmpty ? address : name, address: address,
                                    bonjourName: nil, credential: nil))
        saved = pairedStore.all
        selection = "mac:\(provisionalID)"
        return true
    }

    func rename(_ target: HostTarget, to name: String) {
        guard var host = pairedHost(for: target), !name.isEmpty else { return }
        host.name = name
        pairedStore.save(host, replacing: host.id)
        saved = pairedStore.all
        for connection in connections.values where connection.welcome?.hostID == host.id {
            connection.savedName = name
        }
    }

    /// Connects to this Mac at `address` from now on (another subnet, a new
    /// IP). Set by hand, so pairing offers from that Mac no longer change it.
    /// Returns false, with `lastError` set, for an address that can't be used.
    func setAddress(_ target: HostTarget, to address: String) -> Bool {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var host = pairedHost(for: target) else { return false }
        // Cleared: reached by Bonjour or its other addresses again, if it has any.
        if address.isEmpty, host.address != nil,
           host.bonjourName != nil || host.tailnetAddress != nil || !(host.localAddresses ?? []).isEmpty {
            disconnect(target)
            host.address = nil
            pairedStore.save(host, replacing: host.id)
            saved = pairedStore.all
            return true
        }
        guard HostTarget.endpoint(fromAddress: address) != nil else {
            lastError = String(localized: "Enter an address like mac-mini.local or 192.168.1.20:47800.")
            return false
        }
        disconnect(target)
        host.address = address
        host.fromPeer = false
        pairedStore.save(host, replacing: host.id)
        saved = pairedStore.all
        if selection == target.id { selection = "mac:\(host.id)" }
        return true
    }

    func forget(_ target: HostTarget) {
        disconnect(target)
        if let id = target.savedID ?? target.hostID {
            pairedStore.remove(id: id)
            RemoteAppBundles.remove(hostID: id)
        }
        saved = pairedStore.all
    }

    var allMirrors: [MirrorWindowController] { connections.values.flatMap(\.openMirrors) }
    var allDesktops: [DesktopWindowController] { connections.values.flatMap(\.openDesktops) }

    /// Called before a window opens from the picker; `keepPicker` when ⌥ was held.
    @ObservationIgnored var onPickedWindow: ((_ keepPicker: Bool) -> Void)?

    func launch(_ application: HostApplication, on connection: HostConnection, keepPicker: Bool) {
        connection.onLaunchedWindow = { [weak self] in self?.onPickedWindow?(keepPicker) }
        connection.launch(application)
        if let host = connection.welcome?.hostID { RecentApplications.record(application.path, host: host) }
    }

    func open(_ window: WindowSummary, on connection: HostConnection, keepPicker: Bool) {
        connection.open(window)
        // Opening a window counts as using its app, when the app list says which one it is.
        if let host = connection.welcome?.hostID, let bundle = window.bundleIdentifier,
           let app = connection.applications?.applications.first(where: { $0.bundleIdentifier == bundle }) {
            RecentApplications.record(app.path, host: host)
        }
        onPickedWindow?(keepPicker)
    }
}
