import Darwin
import Foundation
import OSLog

private let log = Logger(subsystem: "com.localhost-copilot.anyremote", category: "UDP")

/// A socket address that can be stored and compared.
public struct SocketAddress: Hashable, Sendable, CustomStringConvertible {
    var storage: sockaddr_storage

    init(_ storage: sockaddr_storage) { self.storage = storage }

    var length: socklen_t {
        storage.ss_family == sa_family_t(AF_INET6)
            ? socklen_t(MemoryLayout<sockaddr_in6>.size) : socklen_t(MemoryLayout<sockaddr_in>.size)
    }

    /// Resolves a numeric or named host (IPv6 scope suffixes like `%en0` allowed).
    public static func resolve(host: String, port: UInt16) -> SocketAddress? {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_family = AF_UNSPEC
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }
        var storage = sockaddr_storage()
        withUnsafeMutableBytes(of: &storage) { raw in
            raw.copyMemory(from: UnsafeRawBufferPointer(start: first.pointee.ai_addr, count: Int(first.pointee.ai_addrlen)))
        }
        return SocketAddress(storage)
    }

    public var description: String {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var service = [CChar](repeating: 0, count: Int(NI_MAXSERV))
        var copy = storage
        let status = withUnsafePointer(to: &copy) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &host, socklen_t(host.count), &service, socklen_t(service.count),
                            NI_NUMERICHOST | NI_NUMERICSERV)
            }
        }
        guard status == 0 else { return "?" }
        return "\(String(cString: host)):\(String(cString: service))"
    }

    public static func == (lhs: SocketAddress, rhs: SocketAddress) -> Bool {
        var l = lhs.storage, r = rhs.storage
        let length = Int(lhs.length)
        guard lhs.length == rhs.length else { return false }
        return memcmp(&l, &r, length) == 0
    }

    public func hash(into hasher: inout Hasher) {
        var copy = storage
        withUnsafeBytes(of: &copy) { hasher.combine(bytes: UnsafeRawBufferPointer(rebasing: $0.prefix(Int(length)))) }
    }
}

/// A non-blocking UDP socket with large buffers and a read source.
///
/// BSD sockets rather than Network.framework so the receive buffer can hold a
/// whole 4:4:4 keyframe burst (~1-2 MB) and every datagram is read in one
/// tight loop per wakeup.
public final class DatagramSocket: @unchecked Sendable {
    private let descriptor: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    public let localPort: UInt16

    /// Called on the socket queue with every datagram read in one wakeup.
    public var onReceive: (@Sendable ([(Data, SocketAddress)]) -> Void)?

    /// Host: a dual-stack socket bound to `port` (0 = ephemeral).
    public convenience init(bindingPort port: UInt16, queue: DispatchQueue) throws {
        try self.init(family: AF_INET6, bindPort: port, queue: queue)
    }

    /// Viewer: an unbound socket of the family of `remote`.
    public convenience init(for remote: SocketAddress, queue: DispatchQueue) throws {
        try self.init(family: Int32(remote.storage.ss_family), bindPort: nil, queue: queue)
    }

    private init(family: Int32, bindPort: UInt16?, queue: DispatchQueue) throws {
        let descriptor = socket(family, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        self.queue = queue
        func fail() -> POSIXError {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            close(descriptor)
            return error
        }
        var off: Int32 = 0
        if family == AF_INET6 {
            setsockopt(descriptor, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
        }
        for option in [SO_RCVBUF, SO_SNDBUF] {
            // Grow until the kernel accepts (bounded by kern.ipc.maxsockbuf).
            for size in [8 << 20, 4 << 20, 2 << 20, 1 << 20] {
                var value = Int32(size)
                if setsockopt(descriptor, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 { break }
            }
        }
        // SO_TRAFFIC_CLASS / SO_TC_VI (sys/socket.h, private section): the
        // "interactive video" service class, as Network.framework uses.
        var trafficClass: Int32 = 700
        setsockopt(descriptor, SOL_SOCKET, 0x1086, &trafficClass, socklen_t(MemoryLayout<Int32>.size))
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)

        if let bindPort {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = bindPort.bigEndian
            address.sin6_addr = in6addr_any
            let status = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            guard status == 0 else { throw fail() }
            var bound = sockaddr_in6()
            var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            _ = withUnsafeMutablePointer(to: &bound) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
            }
            localPort = bound.sin6_port.bigEndian
        } else {
            localPort = 0
        }
        self.descriptor = descriptor
    }

    deinit {
        if let source { source.cancel() } else { close(descriptor) }
    }

    public func resume() {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        let descriptor = descriptor
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    public func cancel() {
        source?.cancel()
    }

    private var buffer = [UInt8](repeating: 0, count: 65_536)

    private func drain() {
        var batch: [(Data, SocketAddress)] = []
        while batch.count < 4096 {
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = buffer.withUnsafeMutableBytes { raw in
                withUnsafeMutablePointer(to: &storage) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(descriptor, raw.baseAddress, raw.count, 0, $0, &length)
                    }
                }
            }
            if count < 0 { break }
            batch.append((Data(buffer[0..<count]), SocketAddress(storage)))
        }
        if !batch.isEmpty { onReceive?(batch) }
    }

    /// Thread-safe. Retries briefly when the interface queue is full.
    @discardableResult
    public func send(_ datagram: Data, to address: SocketAddress) -> Bool {
        var storage = address.storage
        let length = address.length
        for attempt in 0..<20 {
            let sent = datagram.withUnsafeBytes { raw in
                withUnsafePointer(to: &storage) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(descriptor, raw.baseAddress, raw.count, 0, $0, length)
                    }
                }
            }
            if sent >= 0 { return true }
            if errno == ENOBUFS || errno == EAGAIN {
                usleep(useconds_t(50 * (attempt + 1)))
                continue
            }
            log.debug("sendto failed: \(errno)")
            return false
        }
        return false
    }
}
