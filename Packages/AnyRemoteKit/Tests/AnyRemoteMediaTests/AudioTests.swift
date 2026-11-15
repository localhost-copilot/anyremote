import AnyRemoteWire
import Foundation
import Testing
@testable import AnyRemoteMedia

private func sine(frames: Int, start: Int, frequency: Double, rate: Double = 48_000) -> [Float] {
    var samples = [Float](repeating: 0, count: frames * 2)
    for index in 0..<frames {
        let value = Float(0.5 * sin(2 * .pi * frequency * Double(start + index) / rate))
        samples[index * 2] = value
        samples[index * 2 + 1] = -value
    }
    return samples
}

/// Real AudioToolbox round trip of the wire codec.
@Suite struct AACELDCodecTests {
    @Test func sineSurvivesEncodeAndDecode() throws {
        let encoder = try AACELDEncoder()
        #expect(!encoder.format.magicCookie.isEmpty)
        let decoder = try AACELDDecoder(format: encoder.format)
        var decoded: [Float] = []
        var sizes: [Int] = []
        for packet in 0..<100 {
            let input = sine(frames: 480, start: packet * 480, frequency: 1000)
            guard let unit = try input.withUnsafeBufferPointer({ try encoder.encode($0) }) else { continue }
            sizes.append(unit.count)
            try decoder.decode(unit) { decoded.append(contentsOf: $0) }
        }
        #expect(sizes.count >= 95)
        // ~128 kbit/s: 160 bytes per 10 ms packet on average.
        let average = Double(sizes.reduce(0, +)) / Double(sizes.count)
        #expect(average > 60 && average < 400)
        // Skip the codec delay, then compare levels: a 0.5 sine has RMS 0.354.
        let tail = decoded.suffix(48_000 / 2 * 2)
        let left = stride(from: tail.startIndex, to: tail.endIndex, by: 2).map { tail[$0] }
        let right = stride(from: tail.startIndex + 1, to: tail.endIndex, by: 2).map { tail[$0] }
        let rms = { (values: [Float]) in sqrt(values.map { $0 * $0 }.reduce(0, +) / Float(values.count)) }
        #expect(abs(rms(left) - 0.354) < 0.05)
        // The channels stay apart (the right one is inverted).
        let correlation = zip(left, right).map { $0 * $1 }.reduce(0, +) / Float(left.count)
        #expect(correlation < -0.1)
    }

    @Test func resamplerConverts44100To48000() throws {
        let resampler = try #require(AudioResampler(sourceRate: 44_100))
        var output = 0
        for chunk in 0..<10 {
            let input = sine(frames: 441, start: chunk * 441, frequency: 440, rate: 44_100)
            input.withUnsafeBufferPointer { resampler.convert($0) { output += $0.count / 2 } }
        }
        // 4410 frames at 44.1 kHz are 4800 at 48 kHz, less the filter's delay.
        #expect(output > 4600 && output <= 4800)
    }
}

@Suite struct AudioPlayoutBufferTests {
    private func read(_ buffer: inout AudioPlayoutBuffer, _ frames: Int) -> (real: Int, left: [Float]) {
        var left = [Float](repeating: -1, count: frames)
        var right = [Float](repeating: -1, count: frames)
        let real = left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in buffer.read(frames: frames, left: l.baseAddress!, right: r.baseAddress!) }
        }
        return (real, left)
    }

    private func write(_ buffer: inout AudioPlayoutBuffer, frames: Int, value: Float = 0.25) {
        let samples = [Float](repeating: value, count: frames * 2)
        samples.withUnsafeBufferPointer { buffer.write($0) }
    }

    @Test func waitsForTargetThenPlays() {
        var buffer = AudioPlayoutBuffer()
        #expect(buffer.targetFrames == 1440)
        write(&buffer, frames: 960)
        let early = read(&buffer, 512)
        #expect(early.real == 0 && early.left.allSatisfy { $0 == 0 })
        write(&buffer, frames: 960)
        let playing = read(&buffer, 512)
        #expect(playing.real == 512 && playing.left.allSatisfy { $0 == 0.25 })
        #expect(buffer.bufferedFrames == 1920 - 512)
    }

    @Test func underrunRebuffersAndGrowsTarget() {
        var buffer = AudioPlayoutBuffer()
        write(&buffer, frames: 1500)
        _ = read(&buffer, 1000)
        let short = read(&buffer, 1000)
        #expect(short.real == 500)
        #expect(short.left[499] == 0.25 && short.left[500] == 0)
        #expect(buffer.isBuffering)
        // Sound resumes 20 ms later: the network was late.
        _ = read(&buffer, 480)
        write(&buffer, frames: 480)
        #expect(buffer.underruns == 1)
        #expect(buffer.targetFrames == 1440 + 480)
    }

    @Test func longGapIsAPauseNotAnUnderrun() {
        var buffer = AudioPlayoutBuffer()
        write(&buffer, frames: 1500)
        _ = read(&buffer, 1000)
        _ = read(&buffer, 1000)
        for _ in 0..<30 { _ = read(&buffer, 480) } // 300 ms of nothing
        write(&buffer, frames: 480)
        #expect(buffer.underruns == 0)
        #expect(buffer.pauses == 1)
        #expect(buffer.targetFrames == 1440)
    }

    @Test func persistentExcessIsTrimmedToTarget() {
        var buffer = AudioPlayoutBuffer()
        write(&buffer, frames: 1440 + 4800) // 100 ms more than the target
        _ = read(&buffer, 480)
        var reads = 1
        // Keeps writing what it reads, so only trimming lowers the level.
        while buffer.bufferedFrames > 1440 + 480, reads < 200 {
            write(&buffer, frames: 480)
            _ = read(&buffer, 480)
            reads += 1
        }
        #expect(buffer.bufferedFrames <= 1440 + 480)
        // Not before half a second of excess.
        #expect(reads >= 50)
        #expect(buffer.droppedFrames > 4000)
    }

    @Test func ringWrapsAround() {
        var configuration = AudioPlayoutBuffer.Configuration()
        configuration.capacity = 0.02 // 960 frames
        configuration.initialTarget = 0.005
        var buffer = AudioPlayoutBuffer(configuration: configuration)
        for round in 0..<5 {
            let samples: [Float] = (0..<700).flatMap { [Float(round * 1000 + $0), 0] }
            samples.withUnsafeBufferPointer { buffer.write($0) }
            let result = read(&buffer, 700)
            #expect(result.real == 700)
            #expect(result.left.first == Float(round * 1000) && result.left.last == Float(round * 1000 + 699))
        }
    }
}

@Suite struct AudioStreamSenderTests {
    @Test func packetsAreSequentialAndTimed() throws {
        let packets = Locked<[AudioPacket]>([])
        let sender = try AudioStreamSender { datagram in
            if let packet = try? AudioPacket.parse(datagram) { packets.mutate { $0.append(packet) } }
        }
        let start: UInt64 = 1_000_000_000
        for chunk in 0..<50 {
            let frames = sine(frames: 512, start: chunk * 512, frequency: 440)
            frames.withUnsafeBufferPointer {
                sender.submit($0, sampleRate: 48_000, hostNanos: start + UInt64(chunk * 512) * 1_000_000_000 / 48_000)
            }
        }
        // Drain the encoder queue.
        sender.flushForTesting()
        let sent = packets.value
        #expect(sent.count >= 50 * 512 / 480 - 3)
        #expect(sent.enumerated().allSatisfy { $0.element.sequence == UInt32($0.offset) })
        #expect(sent.dropFirst().allSatisfy { $0.previousAccessUnit != nil })
        // 480 frames apart: 10 ms, within a microsecond of rounding.
        for (a, b) in zip(sent, sent.dropFirst()) {
            #expect(abs(Int64(b.captureNanos) - Int64(a.captureNanos) - 10_000_000) < 1_000)
        }
        #expect(abs(Int64(sent[0].captureNanos) - Int64(start)) < 1_000)
    }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ change: (inout Value) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}
