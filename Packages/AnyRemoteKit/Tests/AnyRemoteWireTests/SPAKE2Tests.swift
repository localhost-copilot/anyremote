@testable import AnyRemoteWire
import CryptoKit
import Foundation
import Testing

struct P256GroupTests {
    @Test func scalarMultiplesOfTheGeneratorMatchCryptoKit() throws {
        for _ in 0..<4 {
            let key = P256.KeyAgreement.PrivateKey()
            let scalar = Limbs(bigEndian: key.rawRepresentation)
            let ours = try #require(P256.generator.multiplied(by: scalar).uncompressed)
            #expect(ours == key.publicKey.x963Representation)
        }
    }

    @Test func diffieHellmanOnArbitraryPointsMatchesCryptoKit() throws {
        let a = P256.KeyAgreement.PrivateKey()
        let b = P256.KeyAgreement.PrivateKey()
        let theirs = try a.sharedSecretFromKeyAgreement(with: b.publicKey).withUnsafeBytes { Data($0) }
        let point = try #require(P256.Point(sec1: b.publicKey.x963Representation))
        let shared = try #require(point.multiplied(by: Limbs(bigEndian: a.rawRepresentation)).uncompressed)
        #expect(shared[1..<33] == theirs)
    }

    @Test func compressedPointsDecodeToTheirUncompressedForm() throws {
        let key = P256.KeyAgreement.PrivateKey().publicKey
        let decoded = try #require(P256.Point(sec1: key.compressedRepresentation))
        #expect(decoded.uncompressed == key.x963Representation)
    }

    @Test func theOrderTimesTheGeneratorIsInfinity() {
        let orderMinusOne = P256.order.subtracting(Limbs(1)).difference
        #expect(P256.generator.multiplied(by: P256.order).isInfinity)
        #expect(P256.generator.multiplied(by: orderMinusOne).uncompressed == (-P256.generator).uncompressed)
    }

    @Test func pointsOffTheCurveAreRefused() {
        var bytes = [UInt8](P256.KeyAgreement.PrivateKey().publicKey.x963Representation)
        bytes[64] ^= 1
        #expect(P256.Point(sec1: Data(bytes)) == nil)
        #expect(P256.Point(sec1: Data([4] + [UInt8](repeating: 0xff, count: 64))) == nil)
    }

    @Test func additionAgreesWithMultiplication() {
        let g = P256.generator
        let three = Limbs(3)
        #expect((g + g + g).uncompressed == g.multiplied(by: three).uncompressed)
        #expect((g.doubled() + g).uncompressed == g.multiplied(by: three).uncompressed)
        #expect((g + -g).isInfinity)
    }
}

struct SPAKE2Tests {
    /// RFC 9382, Appendix B, the first vector (A = "server", B = "client").
    @Test func matchesTheRFCTestVector() throws {
        let w = Data(hex: "2ee57912099d31560b3a44b1184b9b4866e904c49d12ac5042c97dca461b1a5f")
        let a = SPAKE2(role: .a, identityA: Data("server".utf8), identityB: Data("client".utf8), password: w,
                       randomScalar: Data(hex: "43dd0fd7215bdcb482879fca3220c6a968e66d70b1356cac18bb26c84a78d729"))
        let b = SPAKE2(role: .b, identityA: Data("server".utf8), identityB: Data("client".utf8), password: w,
                       randomScalar: Data(hex: "dcb60106f276b02606d8ef0a328c02e4b629f84f89786af5befb0bc75b6e66be"))
        #expect(a.share == Data(hex: "04a56fa807caaa53a4d28dbb9853b9815c61a411118a6fe516a8798434751470f9010153ac33d0d5f2047ffdb1a3e42c9b4e6be662766e1eeb4116988ede5f912c"))
        #expect(b.share == Data(hex: "0406557e482bd03097ad0cbaa5df82115460d951e3451962f1eaf4367a420676d09857ccbc522686c83d1852abfa8ed6e4a1155cf8f1543ceca528afb591a1e0b7"))
        let resultA = try a.finish(peerShare: b.share)
        let resultB = try b.finish(peerShare: a.share)
        #expect(resultA.sharedKey == Data(hex: "0e0672dc86f8e45565d338b0540abe69"))
        #expect(resultB.sharedKey == resultA.sharedKey)
        #expect(resultA.confirmation == Data(hex: "58ad4aa88e0b60d5061eb6b5dd93e80d9c4f00d127c65b3b35b1b5281fee38f0"))
        #expect(resultB.confirmation == Data(hex: "d3e2e547f1ae04f2dbdbf0fc4b79f8ecff2dff314b5d32fe9fcef2fb26dc459b"))
        #expect(resultA.verify(peerConfirmation: resultB.confirmation))
        #expect(resultB.verify(peerConfirmation: resultA.confirmation))
    }

    /// The second vector, with an empty identity for A.
    @Test func matchesTheRFCVectorWithoutAnIdentity() throws {
        let w = Data(hex: "0548d8729f730589e579b0475a582c1608138ddf7054b73b5381c7e883e2efae")
        let a = SPAKE2(role: .a, identityA: Data(), identityB: Data("client".utf8), password: w,
                       randomScalar: Data(hex: "403abbe3b1b4b9ba17e3032849759d723939a27a27b9d921c500edde18ed654b"))
        let b = SPAKE2(role: .b, identityA: Data(), identityB: Data("client".utf8), password: w,
                       randomScalar: Data(hex: "903023b6598908936ea7c929bd761af6039577a9c3f9581064187c3049d87065"))
        let resultA = try a.finish(peerShare: b.share)
        #expect(resultA.sharedKey == Data(hex: "642f05c473c2cd79909f9a841e2f30a7"))
        #expect(resultA.confirmation == Data(hex: "47d29e6666af1b7dd450d571233085d7a9866e4d49d2645e2df975489521232b"))
        #expect(try b.finish(peerShare: a.share).confirmation
            == Data(hex: "3313c5cefc361d27fb16847a91c2a73b766ffa90a4839122a9b70a2f6bd1d6df"))
    }

    @Test func theSameCodeAgreesAndAWrongOneFailsConfirmation() throws {
        let right = SPAKE2.passwordScalar("123456", context: "test")
        let wrong = SPAKE2.passwordScalar("123457", context: "test")
        let viewer = SPAKE2(role: .a, identityA: Data("viewer".utf8), identityB: Data("host".utf8), password: right)
        let host = SPAKE2(role: .b, identityA: Data("viewer".utf8), identityB: Data("host".utf8), password: right)
        let hostResult = try host.finish(peerShare: viewer.share)
        let viewerResult = try viewer.finish(peerShare: host.share)
        #expect(viewerResult.verify(peerConfirmation: hostResult.confirmation))
        #expect(viewerResult.sharedKey == hostResult.sharedKey)

        let guesser = SPAKE2(role: .a, identityA: Data("viewer".utf8), identityB: Data("host".utf8), password: wrong)
        let hostAgain = SPAKE2(role: .b, identityA: Data("viewer".utf8), identityB: Data("host".utf8), password: right)
        let guessResult = try guesser.finish(peerShare: hostAgain.share)
        let hostSide = try hostAgain.finish(peerShare: guesser.share)
        #expect(!guessResult.verify(peerConfirmation: hostSide.confirmation))
        #expect(!hostSide.verify(peerConfirmation: guessResult.confirmation))
    }

    @Test func sharesThatAreNotPointsAreRefused() {
        let side = SPAKE2(role: .b, identityA: Data(), identityB: Data(), password: SPAKE2.passwordScalar("1", context: ""))
        #expect(throws: SPAKE2.Failure.invalidShare) { try side.finish(peerShare: Data(repeating: 4, count: 65)) }
        #expect(throws: SPAKE2.Failure.invalidShare) { try side.finish(peerShare: Data()) }
    }
}
