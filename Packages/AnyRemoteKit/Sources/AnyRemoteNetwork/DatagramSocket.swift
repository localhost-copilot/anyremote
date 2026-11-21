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

    /// The address in front of a tailnet socket's datagrams: family (4 or
    /// 6), the port (big-endian), then the 4 or 16 address bytes. An IPv4
    /// address mapped into IPv6 goes as IPv4.
    var frameHeader: [UInt8] {
        var copy = storage
        return withUnsafePointer(to: &copy) { pointer -> [UInt8] in
            if storage.ss_family == sa_family_t(AF_INET) {
                return pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { v4 in
                    let port = UInt16(bigEndian: v4.pointee.sin_port)
                    var address = v4.pointee.sin_addr
                    return [4, UInt8(port >> 8), UInt8(port & 0xff)] + withUnsafeBytes(of: &address) { Array($0) }
                }
            }
            return pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { v6 in
                let port = UInt16(bigEndian: v6.pointee.sin6_port)
                var address = v6.pointee.sin6_addr
                let bytes = withUnsafeBytes(of: &address) { Array($0) }
                if bytes.prefix(12) == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff] {
                    return [4, UInt8(port >> 8), UInt8(port & 0xff)] + bytes.suffix(4)
                }
                return [6, UInt8(port >> 8), UInt8(port & 0xff)] + bytes
            }
        }
    }

    /// Reads the address in front of a tailnet datagram; returns it and the
    /// header's length.
    static func parseFrameHeader(_ bytes: ArraySlice<UInt8>) -> (SocketAddress, Int)? {
        let start = bytes.startIndex
        guard bytes.count >= 3 else { return nil }
        let port = UInt16(bytes[start + 1]) << 8 | UInt16(bytes[start + 2])
        var storage = sockaddr_storage()
        switch bytes[start] {
        case 4 where bytes.count >= 7:
            withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { v4 in
                    v4.pointee.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                    v4.pointee.sin_family = sa_family_t(AF_INET)
                    v4.pointee.sin_port = port.bigEndian
                    withUnsafeMutableBytes(of: &v4.pointee.sin_addr) { $0.copyBytes(from: bytes[(start + 3)..<(start + 7)]) }
                }
            }
            return (SocketAddress(storage), 7)
        case 6 where bytes.count >= 19:
            withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { v6 in
                    v6.pointee.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                    v6.pointee.sin6_family = sa_family_t(AF_INET6)
                    v6.pointee.sin6_port = port.bigEndian
                    withUnsafeMutableBytes(of: &v6.pointee.sin6_addr) { $0.copyBytes(from: bytes[(start + 3)..<(start + 19)]) }
                }
            }
            return (SocketAddress(storage), 19)
        default:
            return nil
        }
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
///
/// A tailnet socket is the embedded node's end for one of its UDP ports, a
/// Unix datagram socket: each datagram carries the peer's address in front
/// (family 4 or 6, port, 4 or 16 address bytes), the sender's coming in and
/// the destination's going out. Everything else is the same.
public final class DatagramSocket: @unchecked Sendable {
    private let descriptor: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private let framed: Bool
    private let onCancel: (@Sendable () -> Void)?
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

    /// A tailnet socket (`TailnetSockets.openDatagram`); `onCancel` closes
    /// its port on the node.
    public init(tailnetDescriptor descriptor: Int32, port: UInt16 = 0, queue: DispatchQueue,
                onCancel: (@Sendable () -> Void)? = nil) {
        Self.configure(descriptor)
        self.descriptor = descriptor
        self.queue = queue
        framed = true
        localPort = port
        self.onCancel = onCancel
    }

    private init(family: Int32, bindPort: UInt16?, queue: DispatchQueue) throws {
        let descriptor = socket(family, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        self.queue = queue
        framed = false
        onCancel = nil
        func fail() -> POSIXError {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            close(descriptor)
            return error
        }
        var off: Int32 = 0
        if family == AF_INET6 {
            setsockopt(descriptor, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
        }
        Self.configure(descriptor)
        // SO_TRAFFIC_CLASS / SO_TC_VI (sys/socket.h, private section): the
        // "interactive video" service class, as Network.framework uses.
        var trafficClass: Int32 = 700
        setsockopt(descriptor, SOL_SOCKET, 0x1086, &trafficClass, socklen_t(MemoryLayout<Int32>.size))

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

    /// Large buffers, no SIGPIPE, non-blocking. A Unix datagram socket's
    /// buffer is 4 KB by default: three datagrams.
    private static func configure(_ descriptor: Int32) {
        for option in [SO_RCVBUF, SO_SNDBUF] {
            // Grow until the kernel accepts (bounded by kern.ipc.maxsockbuf).
            for size in [8 << 20, 4 << 20, 2 << 20, 1 << 20] {
                var value = Int32(size)
                if setsockopt(descriptor, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 { break }
            }
        }
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
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
        onCancel?()
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
            if framed {
                guard let (address, headerSize) = SocketAddress.parseFrameHeader(buffer[0..<count]) else { continue }
                batch.append((Data(buffer[headerSize..<count]), address))
            } else {
                batch.append((Data(buffer[0..<count]), SocketAddress(storage)))
            }
        }
        if !batch.isEmpty { onReceive?(batch) }
    }

    /// Thread-safe. Retries briefly when the interface queue is full.
    @discardableResult
    public func send(_ datagram: Data, to address: SocketAddress) -> Bool {
        var storage = address.storage
        let length = address.length
        let header = framed ? address.frameHeader : []
        for attempt in 0..<20 {
            let sent = datagram.withUnsafeBytes { raw in
                if framed {
                    // The address in front, without copying the datagram.
                    return header.withUnsafeBytes { headerBytes in
                        var parts = [iovec(iov_base: UnsafeMutableRawPointer(mutating: headerBytes.baseAddress),
                                           iov_len: headerBytes.count),
                                     iovec(iov_base: UnsafeMutableRawPointer(mutating: raw.baseAddress), iov_len: raw.count)]
                        return parts.withUnsafeMutableBufferPointer { iov in
                            var message = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: iov.baseAddress,
                                                 msg_iovlen: Int32(iov.count), msg_control: nil, msg_controllen: 0,
                                                 msg_flags: 0)
                            return sendmsg(descriptor, &message, 0)
                        }
                    }
                }
                return withUnsafePointer(to: &storage) {
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
