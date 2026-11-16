import AnyRemoteMedia
import AnyRemoteNetwork
import AnyRemoteWire
import Foundation
import Network
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Client")

public struct ApplicationListing: Sendable {
    public var applications: [HostApplication]
    /// PNG icons keyed by app path.
    public var icons: [String: Data]
}

public struct WindowListing: Sendable {
    public var windows: [WindowSummary]
    public var displays: [DisplaySummary]
    public var thumbnails: [UInt32: Data]
    public var icons: [String: Data]
    /// Host permissions missing right now ("screen-recording", "accessibility", "post-events").
    public var missingPermissions: [String]
}

/// Viewer side of a connection to one host.
///
/// Control messages travel over the sealed TCP channel; video arrives as
/// sealed UDP datagrams on a socket the viewer opens toward the host's
/// datagram port and keeps alive, so it works through stateful firewalls.
public final class RemoteHostClient: @unchecked Sendable {
    public enum Event: Sendable {
        case connected(HostWelcome)
        case disconnected(String?)
        case streamStarted(StreamDescription)
        case streamMoved(streamID: UInt16, frame: CGRect, title: String, windowID: UInt32?)
        case streamEnded(streamID: UInt16, reason: String)
        case resizeApplied(streamID: UInt16, size: CGSize)
        case cursor(CursorImage)
        case menuBar(streamID: UInt16, applicationName: String, menus: [MenuNode])
        case hostReport(streamID: UInt16, HostStreamReport)
        case windowControls(streamID: UInt16, WindowControls)
        case windowStateRequest(streamID: UInt16, HostWindowStateRequest)
        case caret(streamID: UInt16, rect: CGRect?, font: CaretFont?)
        case pasteboard([PasteboardItem])
        /// This Mac's microphone opened or closed for the host, or the host
        /// wanted it and it isn't allowed here.
        case microphone(MicrophoneState)
        /// A drag began on the host under this viewer's press.
        case hostDragBegan(streamID: UInt16, DragManifest)
        /// A notification appeared on the host.
        case notification(HostNotification)
        /// The host's Dock badges changed (all of them).
        case badges([HostBadge])
        /// A menu bar item clicked from here opened this menu on the host.
        case statusItemMenu(id: String, [MenuNode])
    }

    public enum MicrophoneState: Sendable, Equatable {
        case off
        case on
        /// The host wanted the microphone, but this Mac doesn't allow AnyRemote to use it.
        case denied
    }

    public let endpoint: NWEndpoint
    public let clock = RemoteClock()
    private let code: PairingCode
    private let viewerName: String
    /// The screen being worked on, told to the host when connecting.
    public var screen: ViewerScreen?
    private let queue = DispatchQueue(label: "anyremote.client", qos: .userInteractive)
    private let socketQueue = DispatchQueue(label: "anyremote.client.udp", qos: .userInteractive)

    // Queue-confined.
    private var control: ControlConnection?
    private var socket: DatagramSocket?
    private var hostAddress: SocketAddress?
    private var sealer: DatagramSealer?
    private var timers: [DispatchSourceTimer] = []
    private var clockSync = ClockSync()
    private var nextPingID: UInt32 = 0
    private var lastPongNanos: UInt64 = 0
    private var nextRequestID: UInt32 = 0
    private var listings: [UInt32: CheckedContinuation<WindowListing, Error>] = [:]
    private var applicationListings: [UInt32: CheckedContinuation<ApplicationListing, Error>] = [:]
    private var statusItemListings: [UInt32: CheckedContinuation<[HostStatusItem], Error>] = [:]
    private var connectContinuation: CheckedContinuation<HostWelcome, Error>?
    private var finished = false
    public private(set) var welcome: HostWelcome?

    // Socket-queue state behind a lock (also read when attaching).
    private let receiverLock = NSLock()
    private var receivers: [UInt16: WindowStreamReceiver] = [:]
    private var opener: DatagramOpener?
    private var audioReceiver: AudioStreamReceiver?

    // Queue-confined.
    private var wantsAudio = false
    private var maximumBitRate: Int?
    private var offersMicrophone = false
    private var notices = NoticeSubscription(notifications: false, badges: false)
    private var microphone: ViewerMicrophone?

    // Queue-confined.
    private var transfer: FileTransferChannel?
    private let transferLock = NSLock()
    /// Serves the host's fetches of items this viewer offered in a drag.
    /// Called on a queue of the client's.
    nonisolated(unsafe) public var dragResolver: FileTransferChannel.Resolver?

    /// Delivered on the main queue.
    public var onEvent: (@MainActor @Sendable (Event) -> Void)?

    public init(endpoint: NWEndpoint, code: PairingCode, viewerName: String) {
        self.endpoint = endpoint
        self.code = code
        self.viewerName = viewerName
    }

    /// Round trip of the latest ping, in milliseconds.
    public var roundTripMilliseconds: Double? {
        queue.sync { clockSync.latestRoundTripNanos.map { Double($0) / 1_000_000 } }
    }

    // MARK: Connection

    public func connect(takeOver: Bool = false) async throws -> HostWelcome {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                connectContinuation = continuation
                let connection = NWConnection(to: endpoint, using: ControlConnection.parameters())
                let control = ControlConnection(connection: connection,
                                                role: .viewer(code: code, viewerName: viewerName), queue: queue)
                control.onSecured = { [weak self, weak control] info in
                    self?.secured(info)
                    control?.send(.authenticate(viewerName: self?.viewerName ?? "", takeOver: takeOver,
                                                screen: self?.screen))
                }
                control.onMessage = { [weak self] message in self?.handle(message) }
                control.onClose = { [weak self] error in
                    self?.finish(error.map(Self.describe) ?? "The host closed the connection.")
                }
                self.control = control
                control.start()
                let timeout = DispatchSource.makeTimerSource(queue: queue)
                timeout.schedule(deadline: .now() + 10)
                timeout.setEventHandler { [weak self] in
                    guard let self, self.connectContinuation != nil else { return }
                    self.finish(ConnectionError.timedOut.localizedDescription)
                }
                timeout.resume()
                timers.append(timeout)
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? ConnectionError { return error.localizedDescription }
        if let error = error as? NWError {
            switch error {
            case .posix(.ECONNREFUSED): return "The host refused the connection. Is AnyRemote running there?"
            case .posix(.ETIMEDOUT), .posix(.EHOSTUNREACH), .posix(.ENETUNREACH): return "The host is unreachable."
            default: return error.localizedDescription
            }
        }
        return error.localizedDescription
    }

    public func disconnect() {
        queue.async { [self] in
            control?.close(after: .goodbye(reason: "Viewer disconnected."))
            finish(nil)
        }
    }

    private func secured(_ info: SecureSessionInfo) {
        sealer = DatagramSealer(key: info.keys.datagramViewerToHost, sessionID: info.sessionID)
        receiverLock.lock()
        opener = DatagramOpener(key: info.keys.datagramHostToViewer, sessionID: info.sessionID)
        receiverLock.unlock()
    }

    private func didConnect(_ welcome: HostWelcome) {
        self.welcome = welcome
        lastPongNanos = HostClock.nowNanos()
        // Video comes back to the address our keepalives come from.
        if let host = control?.remoteEndpoint?.numericHost,
           let address = SocketAddress.resolve(host: host, port: welcome.datagramPort),
           let socket = try? DatagramSocket(for: address, queue: socketQueue) {
            socket.onReceive = { [weak self] batch in self?.route(batch) }
            socket.resume()
            self.socket = socket
            hostAddress = address
            sendKeepalive()
        } else {
            log.error("could not open the datagram socket toward the host")
        }
        schedule(every: .milliseconds(500)) { [weak self] in self?.sendKeepalive() }
        schedule(every: .seconds(1)) { [weak self] in self?.tick() }
        // A burst of pings converges the clock estimate quickly.
        for index in 0..<6 {
            queue.asyncAfter(deadline: .now() + .milliseconds(index * 40)) { [weak self] in self?.ping() }
        }
        // Ahead of any stream the viewer opens, so none starts above it.
        if let maximumBitRate { control?.send(.maximumBitRate(maximumBitRate)) }
        if wantsAudio { control?.send(.audio(enabled: true)) }
        if offersMicrophone { control?.send(.microphone(enabled: true)) }
        if !notices.isEmpty { control?.send(.notices(notices)) }
        openTransfer()
        connectContinuation?.resume(returning: welcome)
        connectContinuation = nil
        emit(.connected(welcome))
    }

    private func schedule(every interval: DispatchTimeInterval, _ handler: @escaping @Sendable () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: handler)
        timer.resume()
        timers.append(timer)
    }

    private func sendKeepalive() {
        guard let socket, let hostAddress, let sealer,
              let datagram = try? sealer.seal(DatagramKind.keepaliveDatagram) else { return }
        if !socket.send(datagram, to: hostAddress) {
            receiverLock.lock()
            keepaliveFailures += 1
            receiverLock.unlock()
        }
    }

    private func ping() {
        nextPingID &+= 1
        control?.send(.ping(id: nextPingID, viewerTime: HostClock.nowNanos()))
    }

    private func tick() {
        ping()
        if HostClock.nowNanos() - lastPongNanos > 6_000_000_000 {
            finish("The host stopped responding.")
            return
        }
        receiverLock.lock()
        let current = receivers
        receiverLock.unlock()
        for (streamID, receiver) in current {
            let report = receiver.takeReport()
            control?.send(.receiverReport(streamID: streamID, framesReceived: report.framesReceived,
                                          framesDropped: report.framesDropped))
        }
    }

    private func finish(_ reason: String?) {
        guard !finished else { return }
        finished = true
        transfer?.close()
        transfer = nil
        timers.forEach { $0.cancel() }
        timers.removeAll()
        socket?.cancel()
        socket = nil
        let error = ConnectionError.rejected(reason ?? "Disconnected.")
        connectContinuation?.resume(throwing: error)
        connectContinuation = nil
        listings.values.forEach { $0.resume(throwing: error) }
        applicationListings.values.forEach { $0.resume(throwing: error) }
        applicationListings.removeAll()
        statusItemListings.values.forEach { $0.resume(throwing: error) }
        statusItemListings.removeAll()
        listings.removeAll()
        receiverLock.lock()
        let current = receivers
        receivers.removeAll()
        receiverLock.unlock()
        current.values.forEach { $0.close() }
        replaceAudioReceiver(with: nil)
        microphone?.stop()
        microphone = nil
        emit(.disconnected(reason))
    }

    // MARK: Messages

    private func handle(_ message: ControlMessage) {
        switch message {
        case .welcome(let welcome):
            didConnect(welcome)
        case .rejected(let reason), .goodbye(let reason):
            control?.close()
            finish(reason)
        case let .pong(_, viewerTime, hostTime):
            let now = HostClock.nowNanos()
            lastPongNanos = now
            clockSync.add(viewerSent: viewerTime, hostTime: hostTime, viewerReceived: now)
            if let best = clockSync.best { clock.update(offsetNanos: best.offsetNanos) }
        case let .windowList(requestID, windows, displays, thumbnails, icons, missing):
            listings.removeValue(forKey: requestID)?.resume(returning: WindowListing(
                windows: windows, displays: displays, thumbnails: thumbnails, icons: icons,
                missingPermissions: missing))
        case let .applicationList(requestID, applications, icons):
            applicationListings.removeValue(forKey: requestID)?.resume(
                returning: ApplicationListing(applications: applications, icons: icons))
        case let .statusItems(requestID, items):
            statusItemListings.removeValue(forKey: requestID)?.resume(returning: items)
        case let .statusItemMenu(id, menus):
            emit(.statusItemMenu(id: id, menus))
        case .streamStarted(let description):
            emit(.streamStarted(description))
        case let .streamMoved(streamID, frame, title, windowID):
            emit(.streamMoved(streamID: streamID, frame: frame, title: title, windowID: windowID))
        case let .streamEnded(streamID, reason):
            emit(.streamEnded(streamID: streamID, reason: reason))
        case let .resizeApplied(streamID, size):
            emit(.resizeApplied(streamID: streamID, size: size))
        case .cursor(let image):
            emit(.cursor(image))
        case let .menuBar(streamID, applicationName, menus):
            emit(.menuBar(streamID: streamID, applicationName: applicationName, menus: menus))
        case let .hostReport(streamID, report):
            emit(.hostReport(streamID: streamID, report))
        case let .windowControls(streamID, controls):
            emit(.windowControls(streamID: streamID, controls))
        case let .windowStateRequest(streamID, request):
            emit(.windowStateRequest(streamID: streamID, request))
        case let .caret(streamID, rect, font):
            emit(.caret(streamID: streamID, rect: rect, font: font))
        case let .pasteboard(items):
            emit(.pasteboard(items))
        case .audioStream(let format):
            startAudio(format)
        case .microphoneWanted(let wanted):
            microphoneWanted(wanted)
        case let .hostDragBegan(streamID, manifest):
            emit(.hostDragBegan(streamID: streamID, manifest))
        case .hostNotification(let notification):
            emit(.notification(notification))
        case .badges(let badges):
            emit(.badges(badges))
        default:
            log.debug("unexpected message from host")
        }
    }

    private func emit(_ event: Event) {
        let callback = onEvent
        DispatchQueue.main.async { callback?(event) }
    }

    /// Thread-safe.
    public func send(_ message: ControlMessage) {
        queue.async { [self] in control?.send(message) }
    }

    public func listWindows(thumbnailMaxPixels: Int = 480) async throws -> WindowListing {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !finished, let control else {
                    continuation.resume(throwing: ConnectionError.closed)
                    return
                }
                nextRequestID &+= 1
                listings[nextRequestID] = continuation
                control.send(.listWindows(requestID: nextRequestID, thumbnailMaxPixels: thumbnailMaxPixels))
            }
        }
    }

    public func openWindow(_ windowID: UInt32) { send(.openWindow(windowID: windowID)) }

    /// Streams a whole host display (full desktop).
    public func openDisplay(_ displayID: UInt32) { send(.openDisplay(displayID: displayID)) }

    /// Dynamic resolution: the host desktop takes this size (points), or its own with nil.
    public func setDesktopSize(streamID: UInt16, size: CGSize?) { send(.desktopSize(streamID: streamID, size: size)) }

    /// The items on the right of the host's menu bar.
    public func listStatusItems() async throws -> [HostStatusItem] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !finished, let control else {
                    continuation.resume(throwing: ConnectionError.closed)
                    return
                }
                nextRequestID &+= 1
                statusItemListings[nextRequestID] = continuation
                control.send(.listStatusItems(requestID: nextRequestID))
            }
        }
    }

    public func listApplications() async throws -> ApplicationListing {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !finished, let control else {
                    continuation.resume(throwing: ConnectionError.closed)
                    return
                }
                nextRequestID &+= 1
                applicationListings[nextRequestID] = continuation
                control.send(.listApplications(requestID: nextRequestID))
            }
        }
    }

    public func launchApplication(path: String) { send(.launchApplication(path: path)) }

    public func quitApplication(path: String, force: Bool) { send(.quitApplication(path: path, force: force)) }

    // MARK: Drag and drop

    /// A second sealed connection for dragged files, so a large copy never
    /// waits in line with input. Reopened if it drops while connected.
    private func openTransfer() {
        guard !finished, let session = control?.session else { return }
        let token = SessionKeys.randomNonce()
        control?.send(.transferToken(token))
        let transferQueue = DispatchQueue(label: "anyremote.client.transfer", qos: .userInitiated)
        let connection = ControlConnection(connection: NWConnection(to: endpoint, using: ControlConnection.parameters(bulk: true)),
                                           role: .viewer(code: code, viewerName: viewerName), queue: transferQueue)
        let channel = FileTransferChannel(connection: connection)
        connection.onSecured = { [weak connection] _ in
            connection?.send(.transfer(.attach(sessionID: session.sessionID, token: token)))
        }
        channel.resolve = { [weak self] dragID, itemID, reply in
            guard let resolver = self?.dragResolver else { return reply(nil) }
            resolver(dragID, itemID, reply)
        }
        channel.onClose = { [weak self, weak channel] in
            guard let self else { return }
            self.queue.asyncAfter(deadline: .now() + 2) {
                guard !self.finished, self.transfer === channel else { return }
                log.notice("transfer connection closed; reopening")
                self.openTransfer()
            }
        }
        transfer = channel
        transferLock.lock()
        currentTransfer = channel
        transferLock.unlock()
        connection.start()
    }

    private var currentTransfer: FileTransferChannel? // under transferLock

    /// Fetches an item of the host's drag. Thread-safe; callbacks run on a
    /// queue of the channel's.
    @discardableResult
    public func fetchDragItem(dragID: UInt32, itemID: UInt32, to destination: URL,
                              progress: @escaping @Sendable (Int64) -> Void = { _ in },
                              completion: @escaping @Sendable (Result<URL, Error>) -> Void) -> FileTransferChannel.Fetch? {
        transferLock.lock()
        let channel = currentTransfer
        transferLock.unlock()
        guard let channel else {
            completion(.failure(FileTransferChannel.TransferError.closed))
            return nil
        }
        return channel.fetch(dragID: dragID, itemID: itemID, to: destination, progress: progress,
                             completion: completion)
    }

    /// The viewer's drag over the host's surfaces.
    public func sendDrag(_ event: DragEvent) { send(.drag(event)) }

    // MARK: Notifications

    /// Asks the host for its notifications and Dock badges (or to stop).
    public func setNotices(_ subscription: NoticeSubscription) {
        queue.async { [self] in
            guard subscription != notices else { return }
            notices = subscription
            if welcome != nil { control?.send(.notices(subscription)) }
        }
    }

    // MARK: Video

    /// Caps the bit rate of each stream from this host (nil: the host's own
    /// ceilings). Takes effect on the open streams right away.
    public func setMaximumBitRate(_ bitRate: Int?) {
        queue.async { [self] in
            guard bitRate != maximumBitRate else { return }
            maximumBitRate = bitRate
            if welcome != nil { control?.send(.maximumBitRate(bitRate)) }
        }
    }

    // MARK: Sound

    /// Asks the host for the sound of what this viewer shows (or to stop it).
    public func setAudio(enabled: Bool) {
        queue.async { [self] in
            wantsAudio = enabled
            // Before the welcome the host only accepts authentication; the
            // wish is sent once connected then.
            if welcome != nil { control?.send(.audio(enabled: enabled)) }
            if !enabled { replaceAudioReceiver(with: nil) }
        }
    }

    /// Sound statistics since the last call, while sound plays.
    public func takeAudioReport() -> AudioStreamReceiver.Report? {
        receiverLock.lock()
        let receiver = audioReceiver
        receiverLock.unlock()
        return receiver?.takeReport()
    }

    private func startAudio(_ format: AudioStreamFormat?) {
        guard let format, wantsAudio, !finished else {
            replaceAudioReceiver(with: nil)
            return
        }
        do {
            let receiver = try AudioStreamReceiver(format: format)
            receiver.remoteClock = clock
            replaceAudioReceiver(with: receiver)
            log.notice("playing the host's sound")
        } catch {
            log.error("sound decoder unavailable: \(String(describing: error), privacy: .public)")
            replaceAudioReceiver(with: nil)
        }
    }

    private func replaceAudioReceiver(with receiver: AudioStreamReceiver?) {
        receiverLock.lock()
        let previous = audioReceiver
        audioReceiver = receiver
        receiverLock.unlock()
        previous?.close()
    }

    // MARK: Microphone

    /// Lets apps on the host record from this Mac's microphone (or stops it).
    public func setMicrophone(enabled: Bool) {
        queue.async { [self] in
            offersMicrophone = enabled
            if welcome != nil { control?.send(.microphone(enabled: enabled)) }
            if !enabled {
                microphone?.stop()
                microphone = nil
            }
        }
    }

    private func microphoneWanted(_ wanted: Bool) {
        guard offersMicrophone, !finished else { return }
        if wanted, microphone == nil {
            guard let socket, let hostAddress, let sealer else { return }
            microphone = ViewerMicrophone(
                queue: queue,
                sendDatagram: { datagram in
                    guard let sealed = try? sealer.seal(datagram) else { return }
                    socket.send(sealed, to: hostAddress)
                },
                sendControl: { [weak self] message in self?.send(message) },
                onState: { [weak self] state in self?.emit(.microphone(state)) })
        }
        microphone?.setWanted(wanted)
    }

    // MARK: Video

    /// Starts decoding a stream. `onFrame` runs on a decoder thread.
    @discardableResult
    public func attach(streamID: UInt16, stats: PipelineStats,
                       onFrame: @escaping @Sendable (DecodedFrame) -> Void) -> WindowStreamReceiver {
        let receiver = WindowStreamReceiver(streamID: streamID, stats: stats, onFrame: onFrame) { [weak self] in
            self?.send(.requestKeyframe(streamID: streamID))
        }
        receiver.remoteClock = clock
        receiverLock.lock()
        let previous = receivers.updateValue(receiver, forKey: streamID)
        receiverLock.unlock()
        previous?.close()
        send(.requestKeyframe(streamID: streamID))
        return receiver
    }

    public func detach(streamID: UInt16, closeOnHost: Bool = true) {
        receiverLock.lock()
        let receiver = receivers.removeValue(forKey: streamID)
        receiverLock.unlock()
        receiver?.close()
        if closeOnHost { send(.closeStream(streamID: streamID)) }
    }

    private static let simulatedLoss = Double(ProcessInfo.processInfo.environment["ANYREMOTE_DROP"] ?? "") ?? 0

    /// UDP from the host so far: datagrams received, those that didn't open
    /// (wrong session or key), and keepalives that failed to send.
    public var datagramCounts: (received: Int, unreadable: Int, keepaliveFailures: Int) {
        receiverLock.lock()
        defer { receiverLock.unlock() }
        return (datagramsReceived, datagramsUnreadable, keepaliveFailures)
    }
    private var datagramsReceived = 0 // under receiverLock
    private var datagramsUnreadable = 0
    private var keepaliveFailures = 0

    private func route(_ batch: [(Data, SocketAddress)]) {
        receiverLock.lock()
        defer { receiverLock.unlock() }
        datagramsReceived += batch.count
        guard var opener else {
            datagramsUnreadable += batch.count
            return
        }
        var grouped: [UInt16: [Data]] = [:]
        for (datagram, _) in batch {
            // Development: simulated packet loss (`ANYREMOTE_DROP=0.02`).
            if Self.simulatedLoss > 0, Double.random(in: 0..<1) < Self.simulatedLoss { continue }
            guard let plaintext = try? opener.open(datagram) else {
                datagramsUnreadable += 1
                continue
            }
            guard plaintext.count >= 4 else { continue }
            let kind = plaintext[plaintext.startIndex + 1]
            if kind == DatagramKind.audio {
                audioReceiver?.receive(plaintext)
                continue
            }
            guard kind == DatagramKind.video else { continue }
            let start = plaintext.startIndex
            let streamID = UInt16(plaintext[start + 2]) << 8 | UInt16(plaintext[start + 3])
            grouped[streamID, default: []].append(plaintext)
        }
        self.opener = opener
        for (streamID, datagrams) in grouped {
            receivers[streamID]?.receive(datagrams)
        }
    }
}
