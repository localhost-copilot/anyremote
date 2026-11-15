import CryptoKit
import Foundation

/// A host's pairing secret: 100 random bits shown as 20 Crockford base32
/// characters (`XXXXX-XXXXX-XXXXX-XXXXX`). Typed once on each viewer.
public struct PairingCode: Equatable, Hashable, Sendable, CustomStringConvertible {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    public static let length = 20

    /// Canonical form: 20 characters, no separators.
    public let canonical: String

    public init?(_ text: String) {
        var result = ""
        for character in text.uppercased() {
            switch character {
            case "-", " ", "\t", "\n": continue
            case "O": result.append("0")
            case "I", "L": result.append("1")
            default:
                guard Self.alphabet.contains(character) else { return nil }
                result.append(character)
            }
        }
        guard result.count == Self.length else { return nil }
        canonical = result
    }

    public static func generate() -> PairingCode {
        var generator = SystemRandomNumberGenerator()
        let text = String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
        return PairingCode(text)!
    }

    /// Grouped for display.
    public var description: String {
        stride(from: 0, to: Self.length, by: 5).map { start in
            let lower = canonical.index(canonical.startIndex, offsetBy: start)
            return String(canonical[lower..<canonical.index(lower, offsetBy: 5)])
        }.joined(separator: "-")
    }

    public var preSharedKey: SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(canonical.utf8)),
                               salt: Data("anyremote pairing".utf8),
                               info: Data("psk v1".utf8), outputByteCount: 32)
    }
}

/// Estimates the offset between the host clock and the viewer clock from
/// ping/pong exchanges, keeping the sample with the smallest round trip
/// (the one least distorted by queueing).
public struct ClockSync: Sendable {
    public struct Sample: Sendable {
        public var roundTripNanos: UInt64
        /// host − viewer.
        public var offsetNanos: Int64
    }

    private var samples: [Sample] = []
    public let capacity: Int

    public init(capacity: Int = 32) { self.capacity = capacity }

    public mutating func add(viewerSent: UInt64, hostTime: UInt64, viewerReceived: UInt64) {
        guard viewerReceived >= viewerSent else { return }
        let roundTrip = viewerReceived - viewerSent
        let midpoint = Int64(bitPattern: viewerSent &+ roundTrip / 2)
        samples.append(Sample(roundTripNanos: roundTrip, offsetNanos: Int64(bitPattern: hostTime) &- midpoint))
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }

    public var best: Sample? { samples.min { $0.roundTripNanos < $1.roundTripNanos } }

    public var latestRoundTripNanos: UInt64? { samples.last?.roundTripNanos }

    /// Converts a host timestamp to the viewer clock, if synchronized.
    public func viewerTime(fromHost hostNanos: UInt64) -> UInt64? {
        guard let best else { return nil }
        return UInt64(bitPattern: Int64(bitPattern: hostNanos) &- best.offsetNanos)
    }
}
