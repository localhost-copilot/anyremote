import AnyRemoteMedia
import AnyRemoteNetwork
import AnyRemoteWire
import Foundation
import Network
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Client")

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
        case streamMoved(streamID: UInt16, frame: CGRect, title: String)
        case streamEnded(streamID: UInt16, reason: String)
        case resizeApplied(streamID: UInt16, size: CGSize)
        case cursor(CursorImage)
        case menuBar(streamID: UInt16, applicationName: String, menus: [MenuNode])
        case hostReport(streamID: UInt16, HostStreamReport)
        case windowControls(streamID: UInt16, WindowControls)
        case windowStateRequest(streamID: UInt16, HostWindowStateRequest)
    }

    public let endpoint: NWEndpoint
    public let clock = RemoteClock()
    private let code: PairingCode
    private let viewerName: String
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
    private var connectContinuation: CheckedContinuation<HostWelcome, Error>?
    private var finished = false
    public private(set) var welcome: HostWelcome?

    // Socket-queue state behind a lock (also read when attaching).
    private let receiverLock = NSLock()
    private var receivers: [UInt16: WindowStreamReceiver] = [:]
    private var opener: DatagramOpener?

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
                    control?.send(.authenticate(viewerName: self?.viewerName ?? "", takeOver: takeOver))
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
        socket.send(datagram, to: hostAddress)
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
        timers.forEach { $0.cancel() }
        timers.removeAll()
        socket?.cancel()
        socket = nil
        let error = ConnectionError.rejected(reason ?? "Disconnected.")
        connectContinuation?.resume(throwing: error)
        connectContinuation = nil
        listings.values.forEach { $0.resume(throwing: error) }
        listings.removeAll()
        receiverLock.lock()
        let current = receivers
        receivers.removeAll()
        receiverLock.unlock()
        current.values.forEach { $0.close() }
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
        case .streamStarted(let description):
            emit(.streamStarted(description))
        case let .streamMoved(streamID, frame, title):
            emit(.streamMoved(streamID: streamID, frame: frame, title: title))
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

    private func route(_ batch: [(Data, SocketAddress)]) {
        receiverLock.lock()
        defer { receiverLock.unlock() }
        guard var opener else { return }
        var grouped: [UInt16: [Data]] = [:]
        for (datagram, _) in batch {
            guard let plaintext = try? opener.open(datagram), plaintext.count >= 4,
                  plaintext[plaintext.startIndex + 1] == DatagramKind.video else { continue }
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
