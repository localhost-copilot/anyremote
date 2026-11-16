import AnyRemoteWire
import Foundation
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "Transfer")

/// Moves dragged files and folders between Macs over a connection of their
/// own, so a large copy never delays input or video.
///
/// Either side fetches items the other side offered in a drag. An item
/// travels as a `ditto` archive (folders, symbolic links, extended
/// attributes, resource forks and dates intact): `ditto -c` on the sending
/// side streams into chunks, `ditto -x` on the receiving side unpacks them
/// beside the destination, and the result is moved into place. The receiver
/// grants credit as it writes, so neither side buffers more than a window.
///
/// State is confined to the connection's queue (on the host that is the
/// service queue the sessions share, so nothing here blocks it); archive
/// processes are fed and drained on queues of their own.
public final class FileTransferChannel: @unchecked Sendable {
    /// Finds the local file of an offered item, possibly later (contents
    /// another app promised, or that this Mac must itself fetch first).
    public typealias Resolver = @Sendable (_ dragID: UInt32, _ itemID: UInt32,
                                           _ reply: @escaping @Sendable (URL?) -> Void) -> Void

    public enum TransferError: Error, LocalizedError {
        case closed
        case cancelled
        case unavailable(String)
        case archive(String)

        public var errorDescription: String? {
            switch self {
            case .closed: "The connection was closed."
            case .cancelled: "The copy was cancelled."
            case .unavailable(let reason): reason
            case .archive(let reason): reason
            }
        }
    }

    /// A fetch under way.
    public final class Fetch: @unchecked Sendable {
        fileprivate weak var channel: FileTransferChannel?
        fileprivate let requestID: UInt32
        fileprivate init(channel: FileTransferChannel, requestID: UInt32) {
            self.channel = channel
            self.requestID = requestID
        }

        public func cancel() { channel?.cancelFetch(requestID) }
    }

    static let chunkSize = 256 * 1024
    static let window: Int64 = 8 << 20
    static let ditto = URL(fileURLWithPath: "/usr/bin/ditto")

    public let connection: ControlConnection
    private var queue: DispatchQueue { connection.queue }
    /// Serves fetches from the other side. Called on the connection's queue.
    public var resolve: Resolver?
    public var onClose: (@Sendable () -> Void)?

    private let idLock = NSLock()
    private var nextRequestID: UInt32 = 0 // under idLock
    // Queue-confined.
    private var fetches: [UInt32: Incoming] = [:]
    private var sends: [UInt32: Outgoing] = [:]
    private var closed = false

    public init(connection: ControlConnection) {
        self.connection = connection
        // A write to an archive process that exited must fail, not kill the app.
        signal(SIGPIPE, SIG_IGN)
        connection.onMessage = { [weak self] message in
            guard case .transfer(let message) = message else { return }
            self?.handle(message)
        }
        connection.onData = { [weak self] data in self?.receive(data) }
        connection.onClose = { [weak self] _ in self?.connectionClosed() }
    }

    public func close() {
        queue.async { [self] in
            connection.close()
            connectionClosed()
        }
    }

    // MARK: Fetching

    /// Fetches an item into `destination` (the path to create; an existing
    /// item there is replaced). `progress` reports bytes received so far.
    /// Both callbacks run on a queue of the channel's.
    @discardableResult
    public func fetch(dragID: UInt32, itemID: UInt32, to destination: URL,
                      progress: @escaping @Sendable (Int64) -> Void = { _ in },
                      completion: @escaping @Sendable (Result<URL, Error>) -> Void) -> Fetch {
        // Any thread may fetch, including this channel's queue (relaying).
        idLock.lock()
        nextRequestID &+= 1
        let requestID = nextRequestID
        idLock.unlock()
        let handle = Fetch(channel: self, requestID: requestID)
        queue.async { [self] in
            guard !closed else { return completion(.failure(TransferError.closed)) }
            do {
                let incoming = try Incoming(requestID: requestID, destination: destination,
                                            progress: progress, completion: completion)
                incoming.onWritten = { [weak self] bytes in
                    self?.connection.send(.transfer(.credit(requestID: requestID, bytes: bytes)))
                }
                fetches[requestID] = incoming
                connection.send(.transfer(.fetch(requestID: requestID, dragID: dragID, itemID: itemID)))
            } catch {
                completion(.failure(error))
            }
        }
        return handle
    }

    fileprivate func cancelFetch(_ requestID: UInt32) {
        queue.async { [self] in
            guard let incoming = fetches.removeValue(forKey: requestID) else { return }
            connection.send(.transfer(.cancel(requestID: requestID)))
            incoming.finish(error: TransferError.cancelled)
        }
    }

    private func receive(_ data: Data) {
        guard let chunk = try? TransferChunk.decode(data) else { return }
        fetches[chunk.requestID]?.write(chunk.bytes)
    }

    // MARK: Serving

    private func handle(_ message: TransferMessage) {
        guard !closed else { return }
        switch message {
        case let .fetch(requestID, dragID, itemID):
            serve(requestID: requestID, dragID: dragID, itemID: itemID)
        case let .credit(requestID, bytes):
            sends[requestID]?.grant(bytes)
        case let .cancel(requestID):
            sends.removeValue(forKey: requestID)?.cancel()
        case let .ended(requestID, error):
            guard let incoming = fetches.removeValue(forKey: requestID) else { return }
            incoming.finish(error: error.map { TransferError.unavailable($0) })
        case .attach:
            break
        }
    }

    private func serve(requestID: UInt32, dragID: UInt32, itemID: UInt32) {
        guard let resolve else {
            connection.send(.transfer(.ended(requestID: requestID, error: "Nothing is being dragged.")))
            return
        }
        // Reserved now, so a cancel that arrives while resolving is seen.
        let placeholder = Outgoing(requestID: requestID)
        sends[requestID] = placeholder
        resolve(dragID, itemID) { [weak self] url in
            guard let self else { return }
            self.queue.async {
                guard self.sends[requestID] === placeholder, !placeholder.isCancelled else { return }
                guard let url else {
                    self.sends[requestID] = nil
                    self.connection.send(.transfer(.ended(requestID: requestID,
                                                          error: "The dragged item is no longer available.")))
                    return
                }
                placeholder.start(url: url, connection: self.connection) { error in
                    self.queue.async {
                        guard self.sends.removeValue(forKey: requestID) != nil else { return }
                        self.connection.send(.transfer(.ended(requestID: requestID, error: error)))
                    }
                }
            }
        }
    }

    private func connectionClosed() {
        guard !closed else { return }
        closed = true
        for incoming in fetches.values { incoming.finish(error: TransferError.closed) }
        fetches.removeAll()
        for outgoing in sends.values { outgoing.cancel() }
        sends.removeAll()
        onClose?()
    }
}

// MARK: - Sending

/// Streams one item's archive: `ditto -c` → chunks, within the receiver's credit.
private final class Outgoing: @unchecked Sendable {
    let requestID: UInt32
    private let condition = NSCondition()
    // Under `condition`.
    private var credit = FileTransferChannel.window
    private(set) var isCancelled = false
    private var process: Process?

    init(requestID: UInt32) {
        self.requestID = requestID
    }

    func grant(_ bytes: Int64) {
        condition.lock()
        credit += bytes
        condition.signal()
        condition.unlock()
    }

    func cancel() {
        condition.lock()
        isCancelled = true
        let process = self.process
        condition.signal()
        condition.unlock()
        if let process, process.isRunning { process.terminate() }
    }

    func start(url: URL, connection: ControlConnection, done: @escaping @Sendable (String?) -> Void) {
        let process = Process()
        process.executableURL = FileTransferChannel.ditto
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        // A folder is archived with its own name; a file archives under its name anyway.
        process.arguments = (isDirectory.boolValue ? ["-c", "--keepParent"] : ["-c"]) + [url.path, "-"]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return done("Could not read “\(url.lastPathComponent)”.")
        }
        condition.lock()
        self.process = process
        let cancelledEarly = isCancelled
        condition.unlock()
        if cancelledEarly { process.terminate() }

        let requestID = requestID
        Thread.detachNewThread { [self] in
            let reader = output.fileHandleForReading
            var failed: String?
            while true {
                condition.lock()
                while credit <= 0, !isCancelled { condition.wait() }
                let stop = isCancelled
                condition.unlock()
                if stop { break }
                let chunk: Data
                do {
                    chunk = try reader.read(upToCount: FileTransferChannel.chunkSize) ?? Data()
                } catch {
                    failed = "Could not read “\(url.lastPathComponent)”."
                    break
                }
                if chunk.isEmpty { break }
                condition.lock()
                credit -= Int64(chunk.count)
                condition.unlock()
                connection.send(data: TransferChunk.encode(requestID: requestID, bytes: chunk))
            }
            process.waitUntilExit()
            if failed == nil, !isCancelled, process.terminationStatus != 0 {
                let message = String(data: errors.fileHandleForReading.availableData, encoding: .utf8) ?? ""
                log.error("ditto -c failed: \(message, privacy: .public)")
                failed = "Could not read “\(url.lastPathComponent)”."
            }
            done(failed)
        }
    }
}

// MARK: - Receiving

/// Unpacks one item's archive with `ditto -x` beside its destination, then moves it there.
private final class Incoming: @unchecked Sendable {
    let requestID: UInt32
    let destination: URL
    private let progress: @Sendable (Int64) -> Void
    private let completion: @Sendable (Result<URL, Error>) -> Void
    /// Bytes now written; the sender may send as many more.
    var onWritten: (@Sendable (Int64) -> Void)?
    private let writeQueue = DispatchQueue(label: "anyremote.transfer.write", qos: .userInitiated)
    private let process = Process()
    private let input = Pipe()
    private let staging: URL
    // Write-queue-confined.
    private var received: Int64 = 0
    private var failed = false
    private var finished = false

    init(requestID: UInt32, destination: URL, progress: @escaping @Sendable (Int64) -> Void,
         completion: @escaping @Sendable (Result<URL, Error>) -> Void) throws {
        self.requestID = requestID
        self.destination = destination
        self.progress = progress
        self.completion = completion
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        // On the destination's volume, so the final move is a rename.
        staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                              appropriateFor: parent, create: true)
        process.executableURL = FileTransferChannel.ditto
        process.arguments = ["-x", "-", staging.path]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    func write(_ bytes: Data) {
        writeQueue.async { [self] in
            guard !failed, !finished else { return }
            do {
                try input.fileHandleForWriting.write(contentsOf: bytes)
            } catch {
                failed = true
                return
            }
            received += Int64(bytes.count)
            progress(received)
            onWritten?(Int64(bytes.count))
        }
    }

    /// After the last chunk (nil) or on failure.
    func finish(error: Error?) {
        writeQueue.async { [self] in
            guard !finished else { return }
            finished = true
            try? input.fileHandleForWriting.close()
            if error != nil, process.isRunning { process.terminate() }
            process.waitUntilExit()
            defer { try? FileManager.default.removeItem(at: staging) }
            if let error { return completion(.failure(error)) }
            guard !failed, process.terminationStatus == 0 else {
                return completion(.failure(FileTransferChannel.TransferError.archive(
                    "Could not save “\(destination.lastPathComponent)”.")))
            }
            do {
                let entries = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
                guard let entry = entries.first, entries.count == 1 else {
                    throw FileTransferChannel.TransferError.archive("The copy arrived incomplete.")
                }
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: entry)
                } else {
                    try FileManager.default.moveItem(at: entry, to: destination)
                }
                completion(.success(destination))
            } catch {
                completion(.failure(error))
            }
        }
    }
}
