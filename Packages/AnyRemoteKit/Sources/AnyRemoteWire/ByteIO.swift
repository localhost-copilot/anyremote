import Foundation

public enum WireError: Error, Equatable, Sendable {
    case truncated
    case badMagic
    case unsupportedVersion(UInt8)
    case unknownKind(UInt8)
    case invalidField(String)
    case oversized
    case authenticationFailed
    case replayed
}

/// Big-endian byte writer.
struct ByteWriter {
    private(set) var data = Data()

    init(capacity: Int = 0) {
        data.reserveCapacity(capacity)
    }

    mutating func u8(_ value: UInt8) { data.append(value) }

    mutating func u16(_ value: UInt16) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func u32(_ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func u64(_ value: UInt64) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func bytes(_ value: Data) { data.append(value) }
}

/// Big-endian byte reader over a contiguous buffer. Every read is bounds-checked.
struct ByteReader {
    private let data: Data
    private(set) var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    var remaining: Int { data.endIndex - offset }

    private mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw WireError.truncated }
        let slice = data[offset..<(offset + count)]
        offset += count
        return slice
    }

    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw WireError.truncated }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func u16() throws -> UInt16 {
        try take(2).reduce(0) { $0 << 8 | UInt16($1) }
    }

    mutating func u32() throws -> UInt32 {
        try take(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func u64() throws -> UInt64 {
        try take(8).reduce(0) { $0 << 8 | UInt64($1) }
    }

    mutating func bytes(_ count: Int) throws -> Data {
        Data(try take(count))
    }

    mutating func rest() -> Data {
        defer { offset = data.endIndex }
        return Data(data[offset..<data.endIndex])
    }
}

/// RFC 1982-style comparison for wrapping 32-bit sequence numbers.
@inline(__always)
func sequence(_ lhs: UInt32, isBefore rhs: UInt32) -> Bool {
    Int32(bitPattern: lhs &- rhs) < 0
}
