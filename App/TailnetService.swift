import AnyRemoteHost
import AnyRemoteNetwork
import AnyRemoteTailnet
import AppKit
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Tailnet")

/// Tailscale for AnyRemote. With *Connect Through Tailscale* on, AnyRemote
/// runs a node of its own (`EmbeddedTailnet`): a device on the user's
/// tailnet, through which this Mac hosts and reaches other Macs there,
/// without the Tailscale app. When the Tailscale app is connected on this
/// Mac, the system routes the tailnet already and no node runs (one device
/// per Mac, and no Tailscale inside Tailscale).
@MainActor
@Observable
final class TailnetService {
    enum Phase: Equatable {
        case off
        /// The Tailscale app is connected here and carries the tailnet.
        case systemTailscale
        case starting
        /// Waiting for a sign-in at this URL (nil until the node has one).
        case needsLogin(URL?)
        /// Signed in; the tailnet's admin has to approve the device.
        case needsApproval
        case running
        case failed(String)
    }

    private(set) var phase: Phase = .off
    private(set) var status: TailnetStatus?
    /// Other Macs on the tailnet where AnyRemote answers, found by the node.
    private(set) var anyRemoteMacs: [TailnetStatus.Peer] = []
    /// The Tailscale app is connected on this Mac.
    private(set) var systemConnected = TailnetAddress.systemTailscaleIsConnected
    private(set) var isEnabled = UserDefaults.standard.bool(forKey: TailnetService.enabledKey)

    static let enabledKey = "TailnetEnabled"
    @ObservationIgnored private let node = EmbeddedTailnet.shared
    @ObservationIgnored private let hostService: HostService
    @ObservationIgnored private let work = DispatchQueue(label: "anyremote.tailnet", qos: .userInitiated)
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var nodeStarted = false
    @ObservationIgnored private var lastProbe = Date.distantPast
    @ObservationIgnored private var probing = false
    /// The Macs where AnyRemote answers, after each search.
    @ObservationIgnored var onFoundMacs: (([TailnetStatus.Peer]) -> Void)?

    init(hostService: HostService) {
        self.hostService = hostService
    }

    /// The node's sockets, while it's on the tailnet.
    var sockets: (any TailnetSockets)? { phase == .running ? node : nil }

    /// Tailnet addresses can be reached from here (the app or the node).
    var isReachable: Bool { systemConnected || phase == .running }

    /// Whether a tailnet address is reached through the node rather than
    /// this Mac's own network.
    var routesThroughNode: Bool { !systemConnected && phase == .running }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// A development launch turns the node on for itself (`--tailnet`).
    func enableForThisLaunch() {
        isEnabled = true
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        isEnabled = enabled
        refresh()
    }

    func signIn() {
        if case .needsLogin(let url?) = phase {
            NSWorkspace.shared.open(url)
            return
        }
        work.async { [node] in
            do { try node.login() } catch { log.error("login failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func signOut() {
        work.async { [node] in
            do { try node.logout() } catch { log.error("logout failed: \(error.localizedDescription, privacy: .public)") }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.refresh() } }
        }
    }

    // MARK: State

    private func refresh() {
        systemConnected = TailnetAddress.systemTailscaleIsConnected
        guard isEnabled, !systemConnected else {
            if nodeStarted { stopNode() }
            phase = isEnabled ? .systemTailscale : .off
            status = nil
            anyRemoteMacs = []
            hostService.setTailnet(nil)
            return
        }
        guard nodeStarted else { return startNode() }
        work.async { [node] in
            let status = node.status()
            DispatchQueue.main.async { MainActor.assumeIsolated { self.apply(status) } }
        }
    }

    private func startNode() {
        nodeStarted = true
        phase = .starting
        let directory = AnyRemoteStorage.directory.appendingPathComponent("Tailscale", isDirectory: true)
        let hostname = "\(ComputerName.current) AnyRemote"
        // Development and tests: a key instead of the browser, another control server.
        let environment = ProcessInfo.processInfo.environment
        let controlURL = environment["ANYREMOTE_TAILNET_CONTROL_URL"], authKey = environment["ANYREMOTE_TAILNET_AUTHKEY"]
        work.async { [node] in
            do {
                try node.start(stateDirectory: directory, hostname: hostname, controlURL: controlURL, authKey: authKey)
                log.notice("tailnet node started")
            } catch {
                log.error("tailnet node failed to start: \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.nodeStarted = false
                        self.phase = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func stopNode() {
        nodeStarted = false
        hostService.setTailnet(nil)
        work.async { [node] in node.stop() }
        log.notice("tailnet node stopped")
    }

    private func apply(_ status: TailnetStatus?) {
        guard nodeStarted else { return }
        self.status = status
        let phase: Phase
        switch status?.state {
        case "Running"?: phase = .running
        case "NeedsLogin"?: phase = .needsLogin(status?.authURL.flatMap { $0.isEmpty ? nil : URL(string: $0) })
        case "NeedsMachineAuth"?: phase = .needsApproval
        default: phase = .starting
        }
        if phase != self.phase {
            log.notice("tailnet: \(status?.state ?? "starting", privacy: .public)")
            self.phase = phase
        }
        hostService.setTailnet(phase == .running ? node : nil)
        if phase == .running, Date().timeIntervalSince(lastProbe) > 60 { probe() }
        if phase != .running { anyRemoteMacs = [] }
    }

    /// Finds the Macs on the tailnet where AnyRemote listens, by connecting
    /// to its port (and closing at once: the host sees a connection that
    /// ends before its hello).
    func probe() {
        guard phase == .running, !probing, let status else { return }
        probing = true
        lastProbe = Date()
        let own = Set(status.device?.addresses ?? [])
        let candidates = status.peers.filter { peer in
            peer.online && peer.os == "macOS" && peer.preferredAddress.map { !own.contains($0) } == true
        }
        work.async { [node] in
            let found = Found()
            DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
                let peer = candidates[index]
                guard let address = peer.preferredAddress,
                      let descriptor = try? node.dial(host: address, port: AnyRemoteService.defaultPort, timeout: 3)
                else { return }
                close(descriptor)
                found.add(peer)
            }
            let macs = found.peers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.probing = false
                    if macs != self.anyRemoteMacs { self.anyRemoteMacs = macs }
                    self.onFoundMacs?(macs)
                }
            }
        }
    }

    /// The peer at a tailnet address, for its connection path.
    func peer(at address: String) -> TailnetStatus.Peer? {
        status?.peers.first { $0.addresses.contains(address) }
    }
}

private final class Found: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TailnetStatus.Peer] = []
    var peers: [TailnetStatus.Peer] { lock.withLock { stored } }
    func add(_ peer: TailnetStatus.Peer) { lock.withLock { stored.append(peer) } }
}
