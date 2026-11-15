import Foundation

/// How a host's sound is encoded, sent when it starts (`ControlMessage.audioStream`).
public struct AudioStreamFormat: Codable, Equatable, Sendable {
    /// "aac-eld": MPEG-4 AAC Enhanced Low Delay, one access unit per packet.
    public var codec: String
    public var sampleRate: Double
    public var channels: Int
    public var framesPerPacket: Int
    /// The encoder's magic cookie (its AudioSpecificConfig), for the decoder.
    public var magicCookie: Data

    public init(codec: String = "aac-eld", sampleRate: Double = 48_000, channels: Int = 2,
                framesPerPacket: Int = 480, magicCookie: Data) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.channels = channels
        self.framesPerPacket = framesPerPacket
        self.magicCookie = magicCookie
    }
}

/// One encoded audio packet as a datagram (plaintext, big-endian):
/// ```
/// u8  version (1)   u8 kind (DatagramKind.audio)
/// u16 reserved (0)
/// u32 sequence      packet index; each packet holds framesPerPacket frames
/// u64 captureNanos  host clock: when its first sample was captured
/// u16 length, [length] access unit
/// u16 length, [length] the previous packet's access unit (0: none)
/// ```
/// Repeating the previous packet lets the viewer fill a single lost packet
/// without waiting; at about 160 bytes per packet that costs little.
public struct AudioPacket: Equatable, Sendable {
    public var sequence: UInt32
    public var captureNanos: UInt64
    public var accessUnit: Data
    /// The access unit of `sequence - 1`, if any.
    public var previousAccessUnit: Data?

    public init(sequence: UInt32, captureNanos: UInt64, accessUnit: Data, previousAccessUnit: Data? = nil) {
        self.sequence = sequence
        self.captureNanos = captureNanos
        self.accessUnit = accessUnit
        self.previousAccessUnit = previousAccessUnit
    }

    public static let version: UInt8 = 1
    static let headerSize = 16

    public func serialized() throws -> Data {
        let previous = previousAccessUnit ?? Data()
        guard !accessUnit.isEmpty, accessUnit.count <= Int(UInt16.max), previous.count <= Int(UInt16.max) else {
            throw WireError.oversized
        }
        var writer = ByteWriter(capacity: Self.headerSize + 4 + accessUnit.count + previous.count)
        writer.u8(Self.version)
        writer.u8(DatagramKind.audio)
        writer.u16(0)
        writer.u32(sequence)
        writer.u64(captureNanos)
        writer.u16(UInt16(accessUnit.count))
        writer.bytes(accessUnit)
        writer.u16(UInt16(previous.count))
        writer.bytes(previous)
        return writer.data
    }

    public static func parse(_ datagram: Data) throws -> AudioPacket {
        var reader = ByteReader(datagram)
        let version = try reader.u8()
        guard version == Self.version else { throw WireError.unsupportedVersion(version) }
        let kind = try reader.u8()
        guard kind == DatagramKind.audio else { throw WireError.unknownKind(kind) }
        _ = try reader.u16()
        let sequence = try reader.u32()
        let captureNanos = try reader.u64()
        let accessUnit = try reader.bytes(Int(try reader.u16()))
        guard !accessUnit.isEmpty else { throw WireError.invalidField("accessUnit") }
        let previous = try reader.bytes(Int(try reader.u16()))
        return AudioPacket(sequence: sequence, captureNanos: captureNanos, accessUnit: accessUnit,
                           previousAccessUnit: previous.isEmpty ? nil : previous)
    }
}
