import CryptoKit
import Foundation

/// The shared pairing secret of AnyRemote before 0.31: 100 random bits
/// shown as 20 Crockford base32 characters (`XXXXX-XXXXX-XXXXX-XXXXX`),
/// one per host for every viewer. Macs paired that way keep using it (see
/// `PairingCredential.legacy`); new pairings get a key of their own.
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

/// The secret one viewer and one host share, made when they paired.
///
/// Pairing (`SPAKE2` with a six-digit code shown on the host) gives each
/// viewer its own key, which the host can revoke alone. The viewer names it
/// by `id` in its hello so the host knows which key to use. Macs paired
/// before 0.31 use the host's shared code instead (`legacy`, no `id`).
public struct PairingCredential: Codable, Hashable, Sendable {
    /// Nil for the legacy shared code.
    public let id: String?
    /// The key (32 bytes), or the legacy code's canonical text.
    private let secret: String

    public init?(id: String, key base64: String) {
        guard let data = Data(base64Encoded: base64), data.count == 32 else { return nil }
        self.id = id
        secret = base64
    }

    public static func legacy(_ code: PairingCode) -> PairingCredential {
        PairingCredential(id: nil, secret: code.canonical)
    }

    private init(id: String?, secret: String) {
        self.id = id
        self.secret = secret
    }

    /// A fresh random key, for offering another Mac the way back.
    public static func generate(id: String = UUID().uuidString) -> PairingCredential {
        var generator = SystemRandomNumberGenerator()
        let key = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        return PairingCredential(id: id, key: key.base64EncodedString())!
    }

    /// The key both sides derive from a pairing's SPAKE2 secret. Bound to
    /// the ID the host chose, so a changed ID makes a key that doesn't work
    /// rather than a mix-up.
    public static func derived(fromPairingSecret secret: Data, id: String) -> PairingCredential {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret),
                                         salt: Data("anyremote pairing".utf8),
                                         info: Data("credential v1 \(id)".utf8), outputByteCount: 32)
            .withUnsafeBytes { Data($0) }
        return PairingCredential(id: id, key: key.base64EncodedString())!
    }

    public var isLegacy: Bool { id == nil }

    /// The key as stored (base64); nil for the legacy code.
    public var key: String? { id == nil ? nil : secret }

    public var legacyCode: PairingCode? { id == nil ? PairingCode(secret) : nil }

    public var preSharedKey: SymmetricKey {
        if id == nil, let code = PairingCode(secret) { return code.preSharedKey }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(base64Encoded: secret) ?? Data()),
                                      salt: Data("anyremote pairing".utf8),
                                      info: Data("psk v2".utf8), outputByteCount: 32)
    }
}

/// A pairing code as the host shows it: six digits, for one pairing only.
public enum PairingDigits {
    public static let count = 6

    public static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return String(format: "%06d", Int.random(in: 0..<1_000_000, using: &generator))
    }

    /// The digits typed, without spaces or dashes; nil unless there are six.
    public static func normalized(_ text: String) -> String? {
        let digits = text.filter(\.isNumber).compactMap(\.wholeNumberValue).map(String.init).joined()
        return digits.count == count && text.allSatisfy({ $0.isNumber || $0 == " " || $0 == "-" }) ? digits : nil
    }

    /// "123 456".
    public static func display(_ digits: String) -> String {
        digits.count == count ? digits.prefix(3) + " " + digits.suffix(3) : digits
    }

    /// The SPAKE2 password scalar for a code between these two Macs.
    public static func passwordScalar(_ digits: String) -> Data {
        SPAKE2.passwordScalar(digits, context: "anyremote pairing v1")
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
