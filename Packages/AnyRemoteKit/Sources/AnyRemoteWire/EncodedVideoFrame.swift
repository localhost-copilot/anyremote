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
    /// Host monotonic time in nanoseconds (sender clock domain) at which the
    /// host shows this frame on its own screen: ScreenCaptureKit's timestamp,
    /// exactly one refresh apart for continuous motion.
    public var captureTimeNanos: UInt64
    /// How long before `captureTimeNanos` the frame was handed to the host
    /// (SCK delivers frames ahead of their display time), in microseconds.
    public var captureLeadMicros: UInt16
    /// For a strip of a larger picture (Apple Screen Sharing style tiles):
    /// where it goes. Strips of one host frame share `captureTimeNanos`.
    public struct Tile: Equatable, Sendable {
        /// Strip number, top to bottom (< 8).
        public var index: UInt8
        /// The strips sent for this host frame, as a bit mask; strips that
        /// didn't change are not sent and keep their previous picture.
        public var mask: UInt8
        /// Top row of the strip in the whole picture, in pixels.
        public var originY: UInt16
        /// Height of the whole picture in pixels (its width is the strip's).
        public var canvasHeight: UInt16

        /// The topmost strip sent for its host frame (counts the frame once).
        public var isFirstOfFrame: Bool { mask & ((1 << index) - 1) == 0 }

        public init(index: UInt8, mask: UInt8, originY: UInt16, canvasHeight: UInt16) {
            self.index = index
            self.mask = mask
            self.originY = originY
            self.canvasHeight = canvasHeight
        }
    }
    /// nil for a whole picture.
    public var tile: Tile?

    /// When the frame was captured (handed over), in the sender clock.
    public var handedOverTimeNanos: UInt64 {
        captureTimeNanos - min(captureTimeNanos, UInt64(captureLeadMicros) * 1000)
    }
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
        lengthPrefixedNALUnits: Data,
        captureLeadMicros: UInt16 = 0,
        tile: Tile? = nil
    ) {
        self.captureLeadMicros = captureLeadMicros
        self.tile = tile
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
    /// 2 added `captureLeadMicros`, 3 the tile fields.
    static let version: UInt8 = 3

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
        writer.u16(captureLeadMicros)
        writer.u8(tile?.index ?? 0)
        writer.u8(tile?.mask ?? 0)
        writer.u16(tile?.originY ?? 0)
        writer.u16(tile?.canvasHeight ?? 0)
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
        guard (1...Self.version).contains(version) else { throw WireError.unsupportedVersion(version) }
        flags = Flags(rawValue: try reader.u8())
        sequence = try reader.u32()
        captureTimeNanos = try reader.u64()
        pixelWidth = try reader.u16()
        pixelHeight = try reader.u16()
        scale = try reader.u8()
        captureLeadMicros = version >= 2 ? try reader.u16() : 0
        if version >= 3 {
            let index = try reader.u8(), mask = try reader.u8()
            let originY = try reader.u16(), canvasHeight = try reader.u16()
            if mask != 0 {
                guard index < 8, mask & (1 << index) != 0, canvasHeight > 0,
                      Int(originY) + Int(pixelHeight) <= Int(canvasHeight)
                else { throw WireError.invalidField("tile") }
                tile = Tile(index: index, mask: mask, originY: originY, canvasHeight: canvasHeight)
            } else {
                tile = nil
            }
        } else {
            tile = nil
        }
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
