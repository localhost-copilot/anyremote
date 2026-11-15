import AnyRemoteWire
@preconcurrency import AVFAudio
import AudioToolbox
import Foundation

public enum AudioCodecError: Error, Equatable {
    case converterUnavailable
    case bufferUnavailable
    case conversionFailed(Int)
}

/// The sound format on the wire: AAC-ELD, 48 kHz stereo, 480 frames (10 ms)
/// per packet. ELD adds about 15 ms of codec delay (Apple's Screen Sharing
/// uses it too), against 100+ ms for plain AAC.
public enum AudioWireFormat {
    public static let sampleRate = 48_000.0
    public static let channels: AVAudioChannelCount = 2
    public static let framesPerPacket = 480
    public static let bitRate = 128_000

    /// Interleaved float PCM, the form captured sound is handled in.
    public static let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                          channels: channels, interleaved: true)!

    static func eld(framesPerPacket: Int = framesPerPacket, sampleRate: Double = sampleRate,
                    channels: Int = Int(channels)) -> AVAudioFormat? {
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC_ELD, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(framesPerPacket), mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0, mReserved: 0)
        return AVAudioFormat(streamDescription: &description)
    }
}

/// Encodes 48 kHz interleaved stereo PCM into AAC-ELD packets of 480 frames.
/// Not thread-safe; use from one queue.
public final class AACELDEncoder {
    public let format: AudioStreamFormat
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioCompressedBuffer

    public init() throws {
        guard let eld = AudioWireFormat.eld(),
              let converter = AVAudioConverter(from: AudioWireFormat.pcm, to: eld) else {
            throw AudioCodecError.converterUnavailable
        }
        converter.bitRate = AudioWireFormat.bitRate
        guard let input = AVAudioPCMBuffer(pcmFormat: AudioWireFormat.pcm,
                                           frameCapacity: AVAudioFrameCount(AudioWireFormat.framesPerPacket))
        else { throw AudioCodecError.bufferUnavailable }
        let maximumPacketSize = max(converter.maximumOutputPacketSize, 1536)
        output = AVAudioCompressedBuffer(format: eld, packetCapacity: 1, maximumPacketSize: maximumPacketSize)
        self.converter = converter
        self.input = input
        format = AudioStreamFormat(sampleRate: AudioWireFormat.sampleRate, channels: Int(AudioWireFormat.channels),
                                   framesPerPacket: AudioWireFormat.framesPerPacket,
                                   magicCookie: converter.magicCookie ?? Data())
    }

    /// Encodes exactly `framesPerPacket` interleaved frames. Returns the
    /// access unit, or nil while the encoder is still filling its look-ahead.
    public func encode(_ frames: UnsafeBufferPointer<Float>) throws -> Data? {
        let count = AudioWireFormat.framesPerPacket
        precondition(frames.count == count * Int(AudioWireFormat.channels))
        input.frameLength = AVAudioFrameCount(count)
        input.floatChannelData![0].update(from: frames.baseAddress!, count: frames.count)
        output.packetCount = 0
        output.byteLength = 0
        var supplied = false
        var error: NSError?
        let input = input
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard !supplied else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil else { throw AudioCodecError.conversionFailed(error?.code ?? -1) }
        guard output.packetCount > 0, output.byteLength > 0 else { return nil }
        let length = output.packetDescriptions.map { Int($0[0].mDataByteSize) } ?? Int(output.byteLength)
        return Data(bytes: output.data, count: length)
    }
}

/// Decodes AAC-ELD access units into 48 kHz interleaved stereo float PCM.
/// Not thread-safe; use from one queue.
public final class AACELDDecoder {
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let output: AVAudioPCMBuffer
    public let framesPerPacket: Int

    public init(format: AudioStreamFormat) throws {
        guard format.codec == "aac-eld", format.channels == Int(AudioWireFormat.channels),
              format.sampleRate == AudioWireFormat.sampleRate,
              let eld = AudioWireFormat.eld(framesPerPacket: format.framesPerPacket),
              let converter = AVAudioConverter(from: eld, to: AudioWireFormat.pcm) else {
            throw AudioCodecError.converterUnavailable
        }
        if !format.magicCookie.isEmpty { converter.magicCookie = format.magicCookie }
        converter.primeMethod = .none
        guard let output = AVAudioPCMBuffer(pcmFormat: AudioWireFormat.pcm,
                                            frameCapacity: AVAudioFrameCount(format.framesPerPacket))
        else { throw AudioCodecError.bufferUnavailable }
        self.converter = converter
        self.inputFormat = eld
        self.output = output
        framesPerPacket = format.framesPerPacket
    }

    /// Decodes one access unit; `body` sees its interleaved samples (empty
    /// while the decoder is priming).
    public func decode(_ accessUnit: Data, _ body: (UnsafeBufferPointer<Float>) -> Void) throws {
        let input = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: 1,
                                            maximumPacketSize: accessUnit.count)
        accessUnit.copyBytes(to: input.data.assumingMemoryBound(to: UInt8.self), count: accessUnit.count)
        input.byteLength = UInt32(accessUnit.count)
        input.packetCount = 1
        input.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(accessUnit.count))
        output.frameLength = 0
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard !supplied else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil else { throw AudioCodecError.conversionFailed(error?.code ?? -1) }
        let samples = Int(output.frameLength) * Int(AudioWireFormat.channels)
        body(UnsafeBufferPointer(start: output.floatChannelData![0], count: samples))
    }
}

/// Converts captured PCM at the capture device's rate and channel count into
/// 48 kHz interleaved stereo. Not thread-safe.
final class AudioResampler {
    let sourceRate: Double
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer

    init?(sourceRate: Double, maximumFrames: Int = 8192) {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate,
                                         channels: AudioWireFormat.channels, interleaved: true),
              let converter = AVAudioConverter(from: source, to: AudioWireFormat.pcm),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(maximumFrames)),
              let output = AVAudioPCMBuffer(
                pcmFormat: AudioWireFormat.pcm,
                frameCapacity: AVAudioFrameCount(Double(maximumFrames) * AudioWireFormat.sampleRate / sourceRate) + 64)
        else { return nil }
        self.sourceRate = sourceRate
        self.converter = converter
        self.input = input
        self.output = output
    }

    var maximumFrames: Int { Int(input.frameCapacity) }

    /// `frames` interleaved stereo at `sourceRate`, at most `maximumFrames`.
    func convert(_ frames: UnsafeBufferPointer<Float>, _ body: (UnsafeBufferPointer<Float>) -> Void) {
        let count = frames.count / 2
        guard count > 0, count <= maximumFrames else { return }
        input.frameLength = AVAudioFrameCount(count)
        input.floatChannelData![0].update(from: frames.baseAddress!, count: frames.count)
        output.frameLength = 0
        var supplied = false
        let input = input
        _ = converter.convert(to: output, error: nil) { _, inputStatus in
            guard !supplied else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        body(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength) * 2))
    }
}
