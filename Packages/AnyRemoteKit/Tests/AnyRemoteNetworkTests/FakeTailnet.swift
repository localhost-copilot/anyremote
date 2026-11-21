import AnyRemoteNetwork
import Darwin
import Foundation

/// An in-process stand-in for the embedded tailnet node, speaking its socket
/// interface (anyremote_tailnet.h): listeners deliver connections as
/// records, datagram sockets carry the peer's address in front. Every port
/// belongs to one address, `address`.
final class FakeTailnet: TailnetSockets, @unchecked Sendable {
    let address = "100.100.1.1"
    private let lock = NSLock()
    private var listeners: [UInt16: Int32] = [:]
    private var ports: [UInt16: (descriptor: Int32, source: DispatchSourceRead)] = [:]
    private var nextPort: UInt16 = 50_000
    private var deliveredCounts: [UInt16: Int] = [:]
    private let queue = DispatchQueue(label: "fake-tailnet")

    var addresses: [String] { [address] }

    /// Datagrams delivered to `port` so far.
    func delivered(to port: UInt16) -> Int { lock.withLock { deliveredCounts[port] ?? 0 } }

    private static func pair(_ kind: Int32) throws -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, kind, 0, &fds) == 0 else { throw POSIXError(.EIO) }
        for fd in fds {
            var size: Int32 = 1 << 20
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        }
        return (fds[0], fds[1])
    }

    func listen(port: UInt16) throws -> Int32 {
        let (app, fake) = try Self.pair(SOCK_STREAM)
        lock.withLock { listeners[port] = fake }
        return app
    }

    func dial(host: String, port: UInt16, timeout: TimeInterval) throws -> Int32 {
        guard let channel = lock.withLock({ listeners[port] }) else { throw TailnetError("connection refused") }
        let (dialer, accepted) = try Self.pair(SOCK_STREAM)
        var record = [UInt8](repeating: 0, count: TailnetListener.recordSize)
        let fd = UInt32(bitPattern: accepted)
        record[0...3] = [UInt8(fd >> 24), UInt8(fd >> 16 & 0xff), UInt8(fd >> 8 & 0xff), UInt8(fd & 0xff)]
        let remote = Array("\(address):40000".utf8)
        record[4] = UInt8(remote.count)
        record.replaceSubrange(5..<(5 + remote.count), with: remote)
        guard write(channel, record, record.count) == record.count else { throw TailnetError("connection refused") }
        return dialer
    }

    func openDatagram(port: UInt16) throws -> (descriptor: Int32, port: UInt16) {
        let (app, fake) = try Self.pair(SOCK_DGRAM)
        let bound: UInt16 = lock.withLock {
            if port != 0 { return port }
            defer { nextPort += 1 }
            return nextPort
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fake, queue: queue)
        source.setEventHandler { [weak self] in self?.forward(from: bound, descriptor: fake) }
        source.setCancelHandler { close(fake) }
        lock.withLock { ports[bound] = (fake, source) }
        source.resume()
        return (app, bound)
    }

    func closeDatagram(port: UInt16) {
        lock.withLock { ports.removeValue(forKey: port) }?.source.cancel()
    }

    /// Routes one framed datagram to the port it's addressed to, framed with
    /// the sender's port.
    private func forward(from sender: UInt16, descriptor: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = read(descriptor, &buffer, buffer.count)
        guard count >= 7, buffer[0] == 4 else { return }
        let destination = UInt16(buffer[1]) << 8 | UInt16(buffer[2])
        guard let target = lock.withLock({ ports[destination]?.descriptor }) else { return }
        var frame: [UInt8] = [4, UInt8(sender >> 8), UInt8(sender & 0xff), 100, 100, 1, 1]
        frame += buffer[7..<count]
        if write(target, frame, frame.count) == frame.count {
            lock.withLock { deliveredCounts[destination, default: 0] += 1 }
        }
    }
}
