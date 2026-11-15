import Foundation
import Testing
@testable import AnyRemoteWire

private func sampleFrame(sequence: UInt32 = 7, keyframe: Bool = true, payloadSize: Int = 5000) -> EncodedVideoFrame {
    var nal = Data()
    let body = Data((0..<payloadSize).map { UInt8($0 & 0xff) })
    withUnsafeBytes(of: UInt32(body.count).bigEndian) { nal.append(contentsOf: $0) }
    nal.append(body)
    return EncodedVideoFrame(
        sequence: sequence,
        captureTimeNanos: 0x0102_0304_0506_0708,
        flags: keyframe ? .keyframe : [],
        pixelWidth: 3840,
        pixelHeight: 1966,
        scale: 2,
        parameterSets: keyframe ? [Data([0x40, 0x01]), Data([0x42, 0x01, 0x01]), Data([0x44, 0x01])] : [],
        lengthPrefixedNALUnits: nal
    )
}

@Suite struct EncodedVideoFrameTests {
    @Test func roundTrips() throws {
        let frame = sampleFrame()
        #expect(try EncodedVideoFrame(serialized: frame.serialized()) == frame)
    }

    @Test func goldenHeader() throws {
        let frame = EncodedVideoFrame(
            sequence: 0xAABB_CCDD, captureTimeNanos: 1, flags: .keyframe,
            pixelWidth: 0x0102, pixelHeight: 0x0304, scale: 2,
            parameterSets: [Data([0x40])],
            lengthPrefixedNALUnits: Data([0, 0, 0, 1, 0x26]),
            captureLeadMicros: 0x0506
        )
        let expected: [UInt8] = [
            0x41, 0x56, 0x02, 0x01,             // magic, version, flags
            0xAA, 0xBB, 0xCC, 0xDD,             // sequence
            0, 0, 0, 0, 0, 0, 0, 1,             // capture time
            0x01, 0x02, 0x03, 0x04, 0x02,       // width, height, scale
            0x05, 0x06,                         // capture lead
            0x01, 0x00, 0x01, 0x40,             // one parameter set
            0, 0, 0, 1, 0x26,                   // NAL units
        ]
        #expect(try frame.serialized() == Data(expected))
    }

    @Test func readsVersion1() throws {
        // Hosts before the capture lead: no lead field.
        let data = Data([
            0x41, 0x56, 0x01, 0x00, 0, 0, 0, 9, 0, 0, 0, 0, 0, 0, 0x27, 0x10,
            0x01, 0x02, 0x03, 0x04, 0x02, 0x00, 0, 0, 0, 1, 0x26,
        ])
        let frame = try EncodedVideoFrame(serialized: data)
        #expect(frame.sequence == 9 && frame.captureLeadMicros == 0 && frame.handedOverTimeNanos == 10_000)
    }

    @Test func handedOverTimeSubtractsTheLead() {
        var frame = sampleFrame()
        frame.captureTimeNanos = 20_000_000
        frame.captureLeadMicros = 9_000
        #expect(frame.handedOverTimeNanos == 11_000_000)
    }

    @Test func rejectsTruncatedNALUnit() throws {
        var data = try sampleFrame().serialized()
        data.removeLast()
        #expect(throws: WireError.truncated) { try EncodedVideoFrame(serialized: data) }
    }

    @Test func rejectsZeroGeometry() throws {
        var frame = sampleFrame()
        frame.pixelWidth = 0
        let data = try frame.serialized()
        #expect(throws: WireError.invalidField("geometry")) { try EncodedVideoFrame(serialized: data) }
    }
}

@Suite struct VideoReassemblyTests {
    private func datagrams(_ sequence: UInt32, size: Int = 3000) throws -> [Data] {
        try VideoFragmenter.fragment(sampleFrame(sequence: sequence, payloadSize: size).serialized(),
                                     streamID: 3, frameSequence: sequence, maximumDatagramSize: 1200)
    }

    @Test func fragmentsRespectDatagramSize() throws {
        let parts = try datagrams(1)
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { $0.count <= 1200 })
    }

    @Test func reassemblesOutOfOrderAndIgnoresDuplicates() throws {
        var reassembler = VideoReassembler(streamID: 3)
        let parts = try datagrams(1)
        #expect(try reassembler.accept(parts[2]).frames.isEmpty)
        #expect(try reassembler.accept(parts[2]).frames.isEmpty)
        #expect(try reassembler.accept(parts[0]).frames.isEmpty)
        let output = try reassembler.accept(parts[1])
        #expect(output.frames.count == 1)
        #expect(try EncodedVideoFrame(serialized: output.frames[0].data) == sampleFrame(sequence: 1, payloadSize: 3000))
        #expect(reassembler.pendingFrameCount == 0)
    }

    @Test func newerCompletionAbandonsOlderPartial() throws {
        var reassembler = VideoReassembler(streamID: 3)
        _ = try reassembler.accept(try datagrams(1)[0])
        var output = VideoReassembler.Output.empty
        for part in try datagrams(2) { output = try reassembler.accept(part) }
        #expect(output.frames.map(\.sequence) == [2])
        #expect(reassembler.pendingFrameCount == 0)
        // Late fragments of the abandoned frame are ignored.
        #expect(try reassembler.accept(try datagrams(1)[1]) == .empty)
    }

    @Test func reportsGapsAcrossWraparound() throws {
        var reassembler = VideoReassembler(streamID: 3)
        for part in try datagrams(UInt32.max - 1, size: 10) { _ = try reassembler.accept(part) }
        var output = VideoReassembler.Output.empty
        for part in try datagrams(1, size: 10) { output = try reassembler.accept(part) }
        // UInt32.max and 0 were skipped.
        #expect(output.droppedFrameCount == 2)
        #expect(output.frames.map(\.sequence) == [1])
    }

    @Test func boundsPendingFrames() throws {
        var reassembler = VideoReassembler(streamID: 3, maximumPendingFrames: 2)
        var dropped: UInt32 = 0
        for sequence: UInt32 in 10...13 { dropped += try reassembler.accept(try datagrams(sequence)[0]).droppedFrameCount }
        #expect(reassembler.pendingFrameCount == 2)
        #expect(dropped == 2)
    }

    @Test func rejectsInvalidFragmentIndex() throws {
        var bad = try datagrams(1)[0]
        bad[bad.startIndex + 8] = 0xff // fragmentIndex high byte
        #expect(throws: WireError.invalidField("fragment index")) { try VideoFragmenter.parse(bad) }
    }
}

@Suite struct KeyframeGateTests {
    @Test func waitsForKeyframeAfterLoss() {
        var gate = KeyframeGate()
        var results: [Bool] = []
        results.append(gate.admit(isKeyframe: false))
        results.append(gate.admit(isKeyframe: true))
        results.append(gate.admit(isKeyframe: false))
        results.append(gate.noteDropped())
        results.append(gate.noteDropped())
        results.append(gate.admit(isKeyframe: false))
        results.append(gate.admit(isKeyframe: true))
        #expect(results == [false, true, true, true, false, false, true])
    }
}

@Suite struct FullDesktopMessageTests {
    @Test func displayStreamRoundTrips() throws {
        let description = StreamDescription(streamID: 3, windowID: 1, role: .display, parentStreamID: nil,
                                            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), layer: 0,
                                            title: "Studio Display", applicationName: "Mac mini")
        for message: ControlMessage in [.openDisplay(displayID: 1), .streamStarted(description),
                                        .desktopSize(streamID: 3, size: CGSize(width: 1280, height: 800)),
                                        .desktopSize(streamID: 3, size: nil)] {
            let data = try ControlCoding.encode(message)
            #expect(try ControlCoding.decode(ControlMessage.self, from: data) == message)
        }
    }

    @Test func displaySummaryWithoutNameDecodes() throws {
        // A summary without the newer fields (name, isMain) still decodes.
        let json = #"{"displayID":1,"frame":[[0,0],[1920,1080]],"visibleFrame":[[0,25],[1920,1055]],"scale":2,"isVirtual":false}"#
        let summary = try ControlCoding.decode(DisplaySummary.self, from: Data(json.utf8))
        #expect(summary.name == nil && summary.isMain == nil && summary.scale == 2)
    }
}
