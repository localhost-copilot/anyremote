import CryptoKit
import Foundation

/// SPAKE2 (RFC 9382, ciphersuite P256-SHA256-HKDF-HMAC): two Macs that know
/// the same short code agree on a key without the code, or anything that
/// would let it be guessed offline, crossing the network.
///
/// Someone watching learns nothing about the code. Someone in the middle
/// gets one guess per run: a wrong guess only shows as a failed
/// confirmation. That is what lets pairing use a six-digit code.
///
/// Party A (the viewer) sends `share` first; party B (the host) answers with
/// its own. Each then calls `finish(peerShare:)`, B sends its confirmation,
/// and A sends its own only after B's checked out.
public struct SPAKE2: Sendable {
    public enum Role: Sendable { case a, b }

    public enum Failure: Error, Equatable {
        case invalidShare
    }

    /// What both sides end up with.
    public struct Result: Sendable {
        /// Ke: the shared secret (16 bytes).
        public let sharedKey: Data
        /// This side's key confirmation, for the other side.
        public let confirmation: Data
        fileprivate let expectedPeerConfirmation: Data

        /// Whether the other side's confirmation matches, i.e. it used the same code.
        public func verify(peerConfirmation: Data) -> Bool {
            peerConfirmation.count == expectedPeerConfirmation.count
                && zip(peerConfirmation, expectedPeerConfirmation).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
        }
    }

    /// Seeds from RFC 9382 §6 for P-256 (compressed SEC1).
    static let m = P256.Point(sec1: Data(hex: "02886e2f97ace46e55ba9dd7242579f2993b64e16ef3dcab95afd497333d8fa12f"))!
    static let n = P256.Point(sec1: Data(hex: "03d8bbd6c639c62937b04d997f38c3770719c629d7014d49a24b4f98baa1292b49"))!

    public let role: Role
    private let identityA: Data
    private let identityB: Data
    private let additionalData: Data
    private let w: Limbs
    private let secret: Limbs
    /// pA or pB, to send to the other side.
    public let share: Data

    /// `password` is the scalar from `passwordScalar`; `randomScalar` is only
    /// given by tests (32 bytes, big-endian).
    public init(role: Role, identityA: Data, identityB: Data, password: Data, additionalData: Data = Data(),
                randomScalar: Data? = nil) {
        self.role = role
        self.identityA = identityA
        self.identityB = identityB
        self.additionalData = additionalData
        w = P256.scalar(reducing: password)
        if let randomScalar {
            secret = P256.scalar(reducing: randomScalar)
        } else {
            // 64 bits more than the order, so reducing it leaves no bias.
            var generator = SystemRandomNumberGenerator()
            secret = P256.scalar(reducing: (0..<40).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        }
        let blind = (role == .a ? Self.m : Self.n).multiplied(by: w)
        share = (P256.generator.multiplied(by: secret) + blind).uncompressed!
    }

    /// w for a code: HKDF-SHA256 to 48 bytes, reduced modulo the group
    /// order (RFC 9382 §3.2). No memory-hard function: SPAKE2 allows no
    /// offline guessing, and every online guess costs a run the host sees.
    public static func passwordScalar(_ password: String, context: String) -> Data {
        let bytes = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(password.utf8)),
                                           salt: Data("anyremote spake2 password".utf8),
                                           info: Data(context.utf8), outputByteCount: 48)
            .withUnsafeBytes { Data($0) }
        return P256.scalar(reducing: bytes).bigEndianData
    }

    /// Takes the other side's share and derives the keys.
    public func finish(peerShare: Data) throws -> Result {
        guard let peer = P256.Point(sec1: peerShare), !peer.isInfinity else { throw Failure.invalidShare }
        let unblind = (role == .a ? Self.n : Self.m).multiplied(by: w)
        let k = (peer + -unblind).multiplied(by: secret)
        guard let kEncoded = k.uncompressed else { throw Failure.invalidShare }
        let (pA, pB) = role == .a ? (share, peerShare) : (peerShare, share)

        var transcript = Data()
        for part in [identityA, identityB, pA, pB, kEncoded, w.bigEndianData] {
            withUnsafeBytes(of: UInt64(part.count).littleEndian) { transcript.append(contentsOf: $0) }
            transcript.append(part)
        }
        let hash = Data(SHA256.hash(data: transcript))
        let ke = hash.prefix(16)
        let ka = hash.suffix(16)
        let confirmationKeys = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ka), salt: Data(),
                                                      info: Data("ConfirmationKeys".utf8) + additionalData,
                                                      outputByteCount: 32)
            .withUnsafeBytes { Data($0) }
        let kcA = SymmetricKey(data: confirmationKeys.prefix(16))
        let kcB = SymmetricKey(data: confirmationKeys.suffix(16))
        let confirmationA = Data(HMAC<SHA256>.authenticationCode(for: transcript, using: kcA))
        let confirmationB = Data(HMAC<SHA256>.authenticationCode(for: transcript, using: kcB))
        return Result(sharedKey: Data(ke),
                      confirmation: role == .a ? confirmationA : confirmationB,
                      expectedPeerConfirmation: role == .a ? confirmationB : confirmationA)
    }
}

extension Data {
    /// From hexadecimal digits (tests and constants).
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
