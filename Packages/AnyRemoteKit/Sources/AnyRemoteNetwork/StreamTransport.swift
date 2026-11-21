import Darwin
import Foundation
import Network

public enum StreamTransportState: Sendable {
    case ready
    case failed(Error)
    case cancelled
}

/// The byte stream under a `ControlConnection`: a Network.framework
/// connection, or a socket of the embedded tailnet node.
///
/// `start` is called once; every other call is made on the queue given to
/// it, and every callback runs there.
public protocol StreamTransport: AnyObject, Sendable {
    var stateHandler: (@Sendable (StreamTransportState) -> Void)? { get set }
    func start(queue: DispatchQueue)
    /// `completion` runs once the bytes are handed to the network.
    func send(_ data: Data, completion: @escaping @Sendable () -> Void)
    /// Delivers the next bytes, up to `maximumLength`, or `isComplete` once
    /// the other side closed. One receive at a time.
    func receive(maximumLength: Int, completion: @escaping @Sendable (Data?, _ isComplete: Bool, Error?) -> Void)
    func cancel()
    /// The other end, once connected.
    var remoteEndpoint: NWEndpoint? { get }
    /// The largest IP packet the path carries (its interface's MTU) once
    /// connected; nil when unknown.
    var pathMTU: Int? { get }
    /// Whether this goes through the embedded tailnet node.
    var isTailnet: Bool { get }
}

/// A Network.framework connection.
public final class NetworkStreamTransport: StreamTransport, @unchecked Sendable {
    public let connection: NWConnection
    public var stateHandler: (@Sendable (StreamTransportState) -> Void)?

    public init(_ connection: NWConnection) {
        self.connection = connection
    }

    public func start(queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.stateHandler?(.ready)
            // Refused or unreachable: report instead of waiting forever.
            case .failed(let error), .waiting(let error): self?.stateHandler?(.failed(error))
            case .cancelled: self?.stateHandler?(.cancelled)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    public func send(_ data: Data, completion: @escaping @Sendable () -> Void) {
        connection.send(content: data, completion: .contentProcessed { _ in completion() })
    }

    public func receive(maximumLength: Int, completion: @escaping @Sendable (Data?, Bool, Error?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
            completion(data, isComplete, error)
        }
    }

    public func cancel() { connection.cancel() }

    public var remoteEndpoint: NWEndpoint? { connection.currentPath?.remoteEndpoint }

    public var pathMTU: Int? {
        // A connected path lists the interface it uses (and only that one).
        connection.currentPath?.availableInterfaces.first.flatMap { PathMTU.interface($0.name) }
    }

    public var isTailnet: Bool { false }
}

/// A connected stream socket: one end of a socketpair whose other end the
/// embedded tailnet node copies to and from a tailnet TCP connection.
/// Either given connected (accepted by a `TailnetListener`) or connected on
/// `start` by `connect`, which may block.
public final class SocketStreamTransport: StreamTransport, @unchecked Sendable {
    public typealias Connect = @Sendable () throws -> Int32

    public var stateHandler: (@Sendable (StreamTransportState) -> Void)?
    public let remoteEndpoint: NWEndpoint?
    public var pathMTU: Int? { PathMTU.tailnet }
    public var isTailnet: Bool { true }

    private var connect: Connect?
    // Queue-confined once started.
    private var queue: DispatchQueue?
    private var descriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var openSources = 0
    private var inbound = Data()
    private var reachedEnd = false
    private var readError: Error?
    private var pendingReceive: (maximumLength: Int, completion: @Sendable (Data?, Bool, Error?) -> Void)?
    private var outbound: [(data: Data, completion: @Sendable () -> Void)] = []
    private var outboundOffset = 0
    private var cancelled = false

    public init(descriptor: Int32, remoteEndpoint: NWEndpoint?) {
        self.descriptor = descriptor
        self.remoteEndpoint = remoteEndpoint
    }

    public init(remoteEndpoint: NWEndpoint, connect: @escaping Connect) {
        self.remoteEndpoint = remoteEndpoint
        self.connect = connect
    }

    deinit {
        if openSources == 0, descriptor >= 0 { close(descriptor) }
    }

    public func start(queue: DispatchQueue) {
        self.queue = queue
        guard let connect else {
            queue.async { [self] in opened(descriptor) }
            return
        }
        self.connect = nil
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                let descriptor = try connect()
                queue.async { [self] in opened(descriptor) }
            } catch {
                queue.async { [self] in
                    guard !cancelled else { return }
                    cancelled = true
                    stateHandler?(.failed(error))
                }
            }
        }
    }

    private func opened(_ descriptor: Int32) {
        guard let queue else { return }
        self.descriptor = descriptor
        if cancelled {
            close(descriptor)
            self.descriptor = -1
            return
        }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [self] in sourceCancelled() }
        openSources += 1
        readSource = source
        source.resume()
        stateHandler?(.ready)
        flush()
    }

    /// The descriptor closes once no source refers to it.
    private func sourceCancelled() {
        openSources -= 1
        if openSources == 0, descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
    }

    // MARK: Reading

    /// Drains what the socket has into `inbound`: the connection's reader
    /// takes it within the same turn of the queue, so this never grows far.
    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while !reachedEnd, readError == nil {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                inbound.append(buffer, count: count)
            } else if count == 0 {
                reachedEnd = true
                readSource?.cancel()
                readSource = nil
            } else if errno == EAGAIN || errno == EINTR {
                break
            } else {
                readError = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        deliver()
    }

    public func receive(maximumLength: Int, completion: @escaping @Sendable (Data?, Bool, Error?) -> Void) {
        pendingReceive = (maximumLength, completion)
        deliver()
    }

    private func deliver() {
        guard let (maximumLength, completion) = pendingReceive else { return }
        if !inbound.isEmpty {
            pendingReceive = nil
            let count = min(maximumLength, inbound.count)
            let data = inbound.prefix(count)
            inbound.removeFirst(count)
            completion(Data(data), false, nil)
        } else if let readError {
            pendingReceive = nil
            completion(nil, false, readError)
        } else if reachedEnd {
            pendingReceive = nil
            completion(nil, true, nil)
        }
    }

    // MARK: Writing

    public func send(_ data: Data, completion: @escaping @Sendable () -> Void) {
        guard !cancelled else { return completion() }
        outbound.append((data, completion))
        if readSource != nil || reachedEnd { flush() }
    }

    private func flush() {
        guard descriptor >= 0, !cancelled else { return }
        while let (data, completion) = outbound.first {
            let remaining = data.count - outboundOffset
            let written = data.withUnsafeBytes { raw in
                write(descriptor, raw.baseAddress!.advanced(by: outboundOffset), remaining)
            }
            if written == remaining {
                outbound.removeFirst()
                outboundOffset = 0
                completion()
            } else if written >= 0 {
                outboundOffset += written
            } else if errno == EAGAIN || errno == EINTR {
                break
            } else {
                fail(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                return
            }
        }
        if outbound.isEmpty {
            writeSource?.cancel()
            writeSource = nil
        } else if writeSource == nil, let queue {
            let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.flush() }
            source.setCancelHandler { [self] in sourceCancelled() }
            openSources += 1
            writeSource = source
            source.resume()
        }
    }

    private func fail(_ error: Error) {
        guard !cancelled else { return }
        readError = error
        deliver()
        cancel()
        stateHandler?(.failed(error))
    }

    public func cancel() {
        guard !cancelled else { return }
        cancelled = true
        let completions = outbound.map(\.completion)
        outbound.removeAll()
        completions.forEach { $0() }
        writeSource?.cancel()
        writeSource = nil
        readSource?.cancel()
        readSource = nil
        if openSources == 0, descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
        if let queue {
            queue.async { [self] in stateHandler?(.cancelled) }
        }
    }
}
