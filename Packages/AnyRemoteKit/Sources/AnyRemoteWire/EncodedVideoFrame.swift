import Foundation

/// One encoded HEVC access unit of a single window stream, plus the geometry
/// the host rendered it at.
///
/// Geometry travels with every frame rather than on a control channel so the
/// viewer always knows the exact pixel/point size of the frame it is showing,
/// even while the host window is being resized.
public struct EncodedVideoFrame: Equatable, Sendable {
    public struct Flags: OptionSet, Sendable, Equatable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let keyframe = Flags(rawValue: 1 << 0)
        /// HEVC with a premultiplied alpha layer (child windows).
        public static let alpha = Flags(rawValue: 1 << 1)
    }

    /// Wrapping per-stream frame counter.
    public var sequence: UInt32
    /// Host monotonic capture time in nanoseconds (sender clock domain).
    public var captureTimeNanos: UInt64
    public var flags: Flags
    /// Encoded picture size in pixels.
    public var pixelWidth: UInt16
    public var pixelHeight: UInt16
    /// Host backing scale (pixels per point) the window was captured at.
    public var scale: UInt8
    /// VPS/SPS/PPS NAL units without length prefixes. Present on keyframes.
    public var parameterSets: [Data]
    /// Access unit NAL units, each preceded by a 4-byte big-endian length.
    public var lengthPrefixedNALUnits: Data

    public init(
        sequence: UInt32,
        captureTimeNanos: UInt64,
        flags: Flags,
        pixelWidth: UInt16,
        pixelHeight: UInt16,
        scale: UInt8,
        parameterSets: [Data],
        lengthPrefixedNALUnits: Data
    ) {
        self.sequence = sequence
        self.captureTimeNanos = captureTimeNanos
        self.flags = flags
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.parameterSets = parameterSets
        self.lengthPrefixedNALUnits = lengthPrefixedNALUnits
    }

    public var isKeyframe: Bool { flags.contains(.keyframe) }
    public var hasAlpha: Bool { flags.contains(.alpha) }

    static let magic: UInt16 = 0x4156 // "AV"
    static let version: UInt8 = 1

    public func serialized() throws -> Data {
        guard parameterSets.count <= Int(UInt8.max) else { throw WireError.oversized }
        var writer = ByteWriter(capacity: 32 + lengthPrefixedNALUnits.count)
        writer.u16(Self.magic)
        writer.u8(Self.version)
        writer.u8(flags.rawValue)
        writer.u32(sequence)
        writer.u64(captureTimeNanos)
        writer.u16(pixelWidth)
        writer.u16(pixelHeight)
        writer.u8(scale)
        writer.u8(UInt8(parameterSets.count))
        for set in parameterSets {
            guard set.count <= Int(UInt16.max) else { throw WireError.oversized }
            writer.u16(UInt16(set.count))
            writer.bytes(set)
        }
        writer.bytes(lengthPrefixedNALUnits)
        return writer.data
    }

    public init(serialized data: Data) throws {
        var reader = ByteReader(data)
        guard try reader.u16() == Self.magic else { throw WireError.badMagic }
        let version = try reader.u8()
        guard version == Self.version else { throw WireError.unsupportedVersion(version) }
        flags = Flags(rawValue: try reader.u8())
        sequence = try reader.u32()
        captureTimeNanos = try reader.u64()
        pixelWidth = try reader.u16()
        pixelHeight = try reader.u16()
        scale = try reader.u8()
        guard pixelWidth > 0, pixelHeight > 0, scale > 0 else {
            throw WireError.invalidField("geometry")
        }
        let setCount = Int(try reader.u8())
        var sets: [Data] = []
        sets.reserveCapacity(setCount)
        for _ in 0..<setCount {
            sets.append(try reader.bytes(Int(try reader.u16())))
        }
        parameterSets = sets
        lengthPrefixedNALUnits = reader.rest()
        try Self.validateLengthPrefixed(lengthPrefixedNALUnits)
    }

    private static func validateLengthPrefixed(_ data: Data) throws {
        var reader = ByteReader(data)
        while reader.remaining > 0 {
            let length = Int(try reader.u32())
            guard length > 0 else { throw WireError.invalidField("empty NAL unit") }
            _ = try reader.bytes(length)
        }
    }
}
