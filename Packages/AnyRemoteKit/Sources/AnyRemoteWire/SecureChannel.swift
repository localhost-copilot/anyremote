import CryptoKit
import Foundation

/// Session keys derived from the pairing secret and both handshake nonces.
///
/// The pairing code (100 random bits) is the pre-shared key; it never crosses
/// the wire. Each session derives independent AES-256-GCM keys per direction
/// and per channel, salted with fresh nonces from both sides, so frames from
/// one session cannot be replayed into another and a passive observer learns
/// nothing that helps an offline search of a 2^100 space.
public struct SessionKeys: Sendable {
    public let controlViewerToHost: SymmetricKey
    public let controlHostToViewer: SymmetricKey
    public let datagramViewerToHost: SymmetricKey
    public let datagramHostToViewer: SymmetricKey

    public init(preSharedKey: SymmetricKey, clientNonce: Data, serverNonce: Data) throws {
        guard clientNonce.count == 32, serverNonce.count == 32 else { throw WireError.invalidField("nonce") }
        let salt = clientNonce + serverNonce
        func derive(_ label: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: preSharedKey, salt: salt,
                                   info: Data("anyremote v1 \(label)".utf8), outputByteCount: 32)
        }
        controlViewerToHost = derive("control v2h")
        controlHostToViewer = derive("control h2v")
        datagramViewerToHost = derive("datagram v2h")
        datagramHostToViewer = derive("datagram h2v")
    }

    public static func randomNonce() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

private func nonce(counter: UInt64) -> AES.GCM.Nonce {
    var bytes = [UInt8](repeating: 0, count: 12)
    withUnsafeBytes(of: counter.bigEndian) { bytes.replaceSubrange(4..<12, with: $0) }
    return try! AES.GCM.Nonce(data: bytes)
}

/// Seals messages of an ordered byte stream. Counters are implicit: the
/// receiver expects exactly the next one, which rejects reordering, replay
/// and truncation-then-splice.
public struct StreamSealer: Sendable {
    private let key: SymmetricKey
    private var counter: UInt64 = 0

    public init(key: SymmetricKey) { self.key = key }

    public mutating func seal(_ plaintext: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce(counter: counter))
        counter += 1
        return box.ciphertext + box.tag
    }
}

public struct StreamOpener: Sendable {
    private let key: SymmetricKey
    private var counter: UInt64 = 0

    public init(key: SymmetricKey) { self.key = key }

    public mutating func open(_ sealed: Data) throws -> Data {
        guard sealed.count >= 16 else { throw WireError.truncated }
        let split = sealed.endIndex - 16
        let box = try AES.GCM.SealedBox(nonce: nonce(counter: counter),
                                        ciphertext: sealed[sealed.startIndex..<split],
                                        tag: sealed[split...])
        do {
            let plaintext = try AES.GCM.open(box, using: key)
            counter += 1
            return plaintext
        } catch {
            throw WireError.authenticationFailed
        }
    }
}

/// Datagram envelope (big-endian):
/// ```
/// u32 sessionID   (cleartext, authenticated)
/// u64 counter     (cleartext, authenticated; nonce)
/// ... ciphertext
/// [16] GCM tag
/// ```
public enum DatagramEnvelope {
    public static let headerSize = 12
    public static let overhead = headerSize + 16

    public static func sessionID(of datagram: Data) -> UInt32? {
        guard datagram.count >= overhead else { return nil }
        var reader = ByteReader(datagram)
        return try? reader.u32()
    }
}

public final class DatagramSealer: @unchecked Sendable {
    private let key: SymmetricKey
    private let sessionID: UInt32
    private let lock = NSLock()
    private var counter: UInt64 = 0

    public init(key: SymmetricKey, sessionID: UInt32) {
        self.key = key
        self.sessionID = sessionID
    }

    /// Thread-safe.
    public func seal(_ plaintext: Data) throws -> Data {
        lock.lock()
        let counter = self.counter
        self.counter += 1
        lock.unlock()
        var header = ByteWriter(capacity: DatagramEnvelope.overhead + plaintext.count)
        header.u32(sessionID)
        header.u64(counter)
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce(counter: counter),
                                   authenticating: header.data)
        var out = header.data
        out.append(box.ciphertext)
        out.append(box.tag)
        return out
    }
}

/// Opens datagrams of one session and rejects replays with a sliding window.
public struct DatagramOpener: Sendable {
    private let key: SymmetricKey
    private let sessionID: UInt32
    private var window = ReplayWindow()

    public init(key: SymmetricKey, sessionID: UInt32) {
        self.key = key
        self.sessionID = sessionID
    }

    public mutating func open(_ datagram: Data) throws -> Data {
        guard datagram.count >= DatagramEnvelope.overhead else { throw WireError.truncated }
        var reader = ByteReader(datagram)
        guard try reader.u32() == sessionID else { throw WireError.invalidField("session") }
        let counter = try reader.u64()
        guard window.mayAccept(counter) else { throw WireError.replayed }
        let start = datagram.startIndex
        let headerEnd = start + DatagramEnvelope.headerSize
        let tagStart = datagram.endIndex - 16
        let box = try AES.GCM.SealedBox(nonce: nonce(counter: counter),
                                        ciphertext: datagram[headerEnd..<tagStart],
                                        tag: datagram[tagStart...])
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(box, using: key, authenticating: datagram[start..<headerEnd])
        } catch {
            throw WireError.authenticationFailed
        }
        window.record(counter)
        return plaintext
    }
}

/// 1024-entry anti-replay window (RFC 6479 style, simplified).
public struct ReplayWindow: Sendable {
    public static let size: UInt64 = 1024
    private var highest: UInt64?
    private var seen = [UInt64](repeating: 0, count: Int(size / 64))

    public init() {}

    public func mayAccept(_ counter: UInt64) -> Bool {
        guard let highest else { return true }
        if counter > highest { return true }
        if highest - counter >= Self.size { return false }
        let bit = counter % Self.size
        return seen[Int(bit / 64)] & (1 << (bit % 64)) == 0
    }

    public mutating func record(_ counter: UInt64) {
        if let current = highest, counter > current {
            if counter - current >= Self.size {
                for index in seen.indices { seen[index] = 0 }
            } else {
                for value in (current + 1)...counter { clear(value) }
            }
            highest = counter
        } else if highest == nil {
            highest = counter
        }
        let bit = counter % Self.size
        seen[Int(bit / 64)] |= 1 << (bit % 64)
    }

    private mutating func clear(_ value: UInt64) {
        let bit = value % Self.size
        seen[Int(bit / 64)] &= ~(1 << (bit % 64))
    }
}

/// Stream framing for the control connection (big-endian):
/// ```
/// u32 length of what follows
/// u8  kind (0 = cleartext handshake JSON, 1 = sealed control message,
///           2 = sealed raw data: a `TransferChunk`)
/// ... body
/// ```
public enum ControlFrame {
    public static let maximumLength = 32 * 1024 * 1024

    public enum Kind: UInt8, Sendable {
        case handshake = 0
        case sealed = 1
        case sealedData = 2
    }

    public static func encode(kind: Kind, body: Data) -> Data {
        var writer = ByteWriter(capacity: 5 + body.count)
        writer.u32(UInt32(body.count + 1))
        writer.u8(kind.rawValue)
        writer.bytes(body)
        return writer.data
    }
}

/// Incremental parser for `ControlFrame`s.
public struct ControlFrameParser: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) throws -> [(ControlFrame.Kind, Data)] {
        buffer.append(data)
        var frames: [(ControlFrame.Kind, Data)] = []
        var offset = buffer.startIndex
        while buffer.endIndex - offset >= 4 {
            var reader = ByteReader(buffer[offset..<(offset + 4)])
            let length = Int(try reader.u32())
            guard length >= 1, length <= ControlFrame.maximumLength else { throw WireError.oversized }
            guard buffer.endIndex - offset - 4 >= length else { break }
            let kindByte = buffer[offset + 4]
            guard let kind = ControlFrame.Kind(rawValue: kindByte) else { throw WireError.unknownKind(kindByte) }
            frames.append((kind, Data(buffer[(offset + 5)..<(offset + 4 + length)])))
            offset += 4 + length
        }
        if offset > buffer.startIndex {
            buffer = Data(buffer[offset...])
        }
        return frames
    }
}
