import Foundation

/// Datagram framing for video frames.
///
/// Layout (big-endian, 12 bytes):
/// ```
/// u8  version        (1)
/// u8  kind           (1 = video fragment)
/// u16 streamID
/// u32 frameSequence
/// u16 fragmentIndex
/// u16 fragmentCount
/// ... payload
/// ```
public struct VideoFragmentHeader: Equatable, Sendable {
    public static let size = 12
    static let version: UInt8 = 1
    static let kindVideo: UInt8 = 1

    public var streamID: UInt16
    public var frameSequence: UInt32
    public var fragmentIndex: UInt16
    public var fragmentCount: UInt16

    public init(streamID: UInt16, frameSequence: UInt32, fragmentIndex: UInt16, fragmentCount: UInt16) {
        self.streamID = streamID
        self.frameSequence = frameSequence
        self.fragmentIndex = fragmentIndex
        self.fragmentCount = fragmentCount
    }
}

public enum VideoFragmenter {
    /// Splits one serialized frame into datagrams no larger than `maximumDatagramSize`.
    public static func fragment(
        _ frame: Data,
        streamID: UInt16,
        frameSequence: UInt32,
        maximumDatagramSize: Int = 1200
    ) throws -> [Data] {
        let payloadSize = maximumDatagramSize - VideoFragmentHeader.size
        guard payloadSize > 0, !frame.isEmpty else { throw WireError.invalidField("fragment size") }
        let count = (frame.count + payloadSize - 1) / payloadSize
        guard count <= Int(UInt16.max) else { throw WireError.oversized }

        var datagrams: [Data] = []
        datagrams.reserveCapacity(count)
        var start = frame.startIndex
        for index in 0..<count {
            let end = min(start + payloadSize, frame.endIndex)
            var writer = ByteWriter(capacity: VideoFragmentHeader.size + (end - start))
            writer.u8(VideoFragmentHeader.version)
            writer.u8(VideoFragmentHeader.kindVideo)
            writer.u16(streamID)
            writer.u32(frameSequence)
            writer.u16(UInt16(index))
            writer.u16(UInt16(count))
            writer.bytes(frame[start..<end])
            datagrams.append(writer.data)
            start = end
        }
        return datagrams
    }

    public static func parse(_ datagram: Data) throws -> (VideoFragmentHeader, Data) {
        var reader = ByteReader(datagram)
        let version = try reader.u8()
        guard version == VideoFragmentHeader.version else { throw WireError.unsupportedVersion(version) }
        let kind = try reader.u8()
        guard kind == VideoFragmentHeader.kindVideo else { throw WireError.unknownKind(kind) }
        let header = VideoFragmentHeader(
            streamID: try reader.u16(),
            frameSequence: try reader.u32(),
            fragmentIndex: try reader.u16(),
            fragmentCount: try reader.u16()
        )
        guard header.fragmentCount > 0, header.fragmentIndex < header.fragmentCount else {
            throw WireError.invalidField("fragment index")
        }
        return (header, reader.rest())
    }
}

/// Reassembles fragments of one stream into complete frames.
///
/// Policy is latest-wins: once a frame completes, any older incomplete frame
/// is abandoned and reported as dropped so the receiver can request a
/// keyframe. Frames older than the last delivered one are ignored.
public struct VideoReassembler: Sendable {
    public struct Output: Equatable, Sendable {
        public var frames: [(sequence: UInt32, data: Data)]
        /// Frames known to be lost or abandoned by this call.
        public var droppedFrameCount: UInt32

        static let empty = Output(frames: [], droppedFrameCount: 0)

        public static func == (lhs: Output, rhs: Output) -> Bool {
            lhs.droppedFrameCount == rhs.droppedFrameCount
                && lhs.frames.map(\.sequence) == rhs.frames.map(\.sequence)
                && lhs.frames.map(\.data) == rhs.frames.map(\.data)
        }
    }

    private struct Partial {
        var fragments: [Data?]
        var received: Int
    }

    public let streamID: UInt16
    public let maximumPendingFrames: Int
    private var partials: [UInt32: Partial] = [:]
    private var lastDelivered: UInt32?

    public init(streamID: UInt16, maximumPendingFrames: Int = 8) {
        precondition(maximumPendingFrames > 0)
        self.streamID = streamID
        self.maximumPendingFrames = maximumPendingFrames
    }

    public var pendingFrameCount: Int { partials.count }

    public mutating func accept(_ datagram: Data) throws -> Output {
        let (header, payload) = try VideoFragmenter.parse(datagram)
        guard header.streamID == streamID else { return .empty }
        let sequenceNumber = header.frameSequence
        if let lastDelivered, !sequence(lastDelivered, isBefore: sequenceNumber) {
            return .empty
        }

        var dropped: UInt32 = 0
        var partial = partials[sequenceNumber]
            ?? Partial(fragments: Array(repeating: nil, count: Int(header.fragmentCount)), received: 0)
        guard partial.fragments.count == Int(header.fragmentCount) else {
            throw WireError.invalidField("inconsistent fragment count")
        }
        let index = Int(header.fragmentIndex)
        if partial.fragments[index] == nil {
            partial.fragments[index] = payload
            partial.received += 1
        }

        guard partial.received == partial.fragments.count else {
            partials[sequenceNumber] = partial
            if partials.count > maximumPendingFrames,
               let oldest = partials.keys.min(by: { sequence($0, isBefore: $1) }) {
                partials.removeValue(forKey: oldest)
                dropped += 1
            }
            return Output(frames: [], droppedFrameCount: dropped)
        }

        partials.removeValue(forKey: sequenceNumber)
        var frame = Data()
        frame.reserveCapacity(partial.fragments.reduce(0) { $0 + ($1?.count ?? 0) })
        for fragment in partial.fragments { frame.append(fragment!) }

        // Every frame between the previous delivery and this one is lost,
        // including any still-incomplete older partials.
        if let lastDelivered {
            dropped = sequenceNumber &- lastDelivered &- 1
        }
        for key in partials.keys where sequence(key, isBefore: sequenceNumber) {
            partials.removeValue(forKey: key)
        }
        lastDelivered = sequenceNumber
        return Output(frames: [(sequenceNumber, frame)], droppedFrameCount: dropped)
    }
}

/// Decides which decoded-order frames may be submitted to the decoder after
/// loss. After any drop, only a keyframe can restart decoding.
public struct KeyframeGate: Sendable {
    public private(set) var awaitingKeyframe = true

    public init() {}

    /// Returns true when the receiver should ask the sender for a keyframe.
    public mutating func noteDropped() -> Bool {
        let shouldRequest = !awaitingKeyframe
        awaitingKeyframe = true
        return shouldRequest
    }

    public mutating func admit(isKeyframe: Bool) -> Bool {
        if isKeyframe { awaitingKeyframe = false }
        return !awaitingKeyframe
    }
}
