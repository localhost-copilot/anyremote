import Foundation

/// The P-256 group operations SPAKE2 needs and CryptoKit doesn't expose:
/// adding points, multiplying arbitrary points by a scalar, and decoding
/// compressed points.
///
/// Only pairing uses this, once per attempt, so it favours being easy to
/// check over speed: four 64-bit limbs, Montgomery multiplication, Jacobian
/// coordinates and a Montgomery ladder (the same steps for every scalar
/// bit). The tests check it against CryptoKit's own P-256 and RFC 9382.
enum P256 {
    /// p = 2^256 − 2^224 + 2^192 + 2^96 − 1, the field.
    static let field = MontgomeryField(modulus: Limbs(hex: "ffffffff00000001000000000000000000000000ffffffffffffffffffffffff"))
    /// The group order.
    static let order = Limbs(hex: "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551")
    /// y² = x³ − 3x + b.
    static let b = field.toMontgomery(Limbs(hex: "5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b"))
    static let generator = Point(
        x: field.toMontgomery(Limbs(hex: "6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296")),
        y: field.toMontgomery(Limbs(hex: "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5")),
        z: field.one)

    /// A point in Jacobian coordinates (x/z², y/z³), each in Montgomery
    /// form; z = 0 is the point at infinity.
    struct Point {
        var x: Limbs
        var y: Limbs
        var z: Limbs

        static let infinity = Point(x: field.one, y: field.one, z: .zero)

        var isInfinity: Bool { z.isZero }

        func doubled() -> Point {
            let f = P256.field
            if isInfinity { return self }
            // dbl-2001-b, for a = −3.
            let delta = f.square(z)
            let gamma = f.square(y)
            let beta = f.multiply(x, gamma)
            let t = f.multiply(f.subtract(x, delta), f.add(x, delta))
            let alpha = f.add(f.add(t, t), t)
            let beta4 = f.add(f.add(beta, beta), f.add(beta, beta))
            let x3 = f.subtract(f.square(alpha), f.add(beta4, beta4))
            let z3 = f.subtract(f.subtract(f.square(f.add(y, z)), gamma), delta)
            let gamma2 = f.square(gamma)
            let gamma8 = f.add(f.add(f.add(gamma2, gamma2), f.add(gamma2, gamma2)),
                               f.add(f.add(gamma2, gamma2), f.add(gamma2, gamma2)))
            let y3 = f.subtract(f.multiply(alpha, f.subtract(beta4, x3)), gamma8)
            return Point(x: x3, y: y3, z: z3)
        }

        static func + (p: Point, q: Point) -> Point {
            let f = P256.field
            if p.isInfinity { return q }
            if q.isInfinity { return p }
            // add-2007-bl.
            let z1z1 = f.square(p.z)
            let z2z2 = f.square(q.z)
            let u1 = f.multiply(p.x, z2z2)
            let u2 = f.multiply(q.x, z1z1)
            let s1 = f.multiply(f.multiply(p.y, q.z), z2z2)
            let s2 = f.multiply(f.multiply(q.y, p.z), z1z1)
            let h = f.subtract(u2, u1)
            let rHalf = f.subtract(s2, s1)
            if h.isZero {
                return rHalf.isZero ? p.doubled() : .infinity
            }
            let i = f.square(f.add(h, h))
            let j = f.multiply(h, i)
            let r = f.add(rHalf, rHalf)
            let v = f.multiply(u1, i)
            let x3 = f.subtract(f.subtract(f.square(r), j), f.add(v, v))
            let s1j = f.multiply(s1, j)
            let y3 = f.subtract(f.multiply(r, f.subtract(v, x3)), f.add(s1j, s1j))
            let z3 = f.multiply(f.subtract(f.subtract(f.square(f.add(p.z, q.z)), z1z1), z2z2), h)
            return Point(x: x3, y: y3, z: z3)
        }

        static prefix func - (p: Point) -> Point {
            Point(x: p.x, y: P256.field.subtract(.zero, p.y), z: p.z)
        }

        /// `scalar` × this point, for a scalar in normal (not Montgomery) form.
        func multiplied(by scalar: Limbs) -> Point {
            var r0 = Point.infinity
            var r1 = self
            for bit in (0..<256).reversed() {
                if scalar.bit(bit) {
                    r0 = r0 + r1
                    r1 = r1.doubled()
                } else {
                    r1 = r0 + r1
                    r0 = r0.doubled()
                }
            }
            return r0
        }

        /// The affine coordinates in normal form; nil at infinity.
        var affine: (x: Limbs, y: Limbs)? {
            guard !isInfinity else { return nil }
            let f = P256.field
            let zInverse = f.inverse(z)
            let zInverse2 = f.square(zInverse)
            return (f.fromMontgomery(f.multiply(x, zInverse2)),
                    f.fromMontgomery(f.multiply(y, f.multiply(zInverse2, zInverse))))
        }

        /// SEC1 uncompressed: 0x04 ‖ x ‖ y. Infinity has no encoding here.
        var uncompressed: Data? {
            guard let (x, y) = affine else { return nil }
            return Data([4]) + x.bigEndianData + y.bigEndianData
        }

        init(x: Limbs, y: Limbs, z: Limbs) {
            self.x = x
            self.y = y
            self.z = z
        }

        /// Decodes a SEC1 point, uncompressed or compressed, checking that it
        /// is on the curve. (P-256 has cofactor 1, so every point on it is in
        /// the group.)
        init?(sec1 data: Data) {
            let bytes = [UInt8](data)
            let f = P256.field
            guard bytes.count == 65 || bytes.count == 33 else { return nil }
            let xNormal = Limbs(bigEndian: bytes[1..<33])
            guard xNormal < f.modulus else { return nil }
            let x = f.toMontgomery(xNormal)
            let rhs = Self.curveRight(x)
            let y: Limbs
            switch (bytes.count, bytes[0]) {
            case (65, 4):
                let yNormal = Limbs(bigEndian: bytes[33..<65])
                guard yNormal < f.modulus else { return nil }
                y = f.toMontgomery(yNormal)
                guard f.square(y) == rhs else { return nil }
            case (33, 2), (33, 3):
                // p ≡ 3 (mod 4): a square root is rhs^((p+1)/4).
                var root = f.power(rhs, exponent: P256.squareRootExponent)
                guard f.square(root) == rhs else { return nil }
                if f.fromMontgomery(root).bit(0) != (bytes[0] == 3) { root = f.subtract(.zero, root) }
                y = root
            default:
                return nil
            }
            self.init(x: x, y: y, z: f.one)
        }

        /// x³ − 3x + b, for x in Montgomery form.
        private static func curveRight(_ x: Limbs) -> Limbs {
            let f = P256.field
            let x3 = f.multiply(f.square(x), x)
            let threeX = f.add(f.add(x, x), x)
            return f.add(f.subtract(x3, threeX), P256.b)
        }
    }

    /// (p + 1) / 4.
    static let squareRootExponent = Limbs(hex: "3fffffffc0000000400000000000000000000000400000000000000000000000")

    /// A big-endian number of any length, reduced modulo the group order.
    static func scalar(reducing bytes: some Collection<UInt8>) -> Limbs {
        var result = Limbs.zero
        for byte in bytes {
            for shift in stride(from: 7, through: 0, by: -1) {
                // result = 2·result + bit, kept below the order.
                var (doubled, carry) = result.adding(result)
                if carry || !(doubled < order) { doubled = doubled.subtracting(order).difference }
                if (byte >> UInt8(shift)) & 1 == 1 {
                    var (plusOne, carryOne) = doubled.adding(Limbs(1))
                    if carryOne || !(plusOne < order) { plusOne = plusOne.subtracting(order).difference }
                    doubled = plusOne
                }
                result = doubled
            }
        }
        return result
    }
}

/// A 256-bit unsigned number: four 64-bit limbs, least significant first.
struct Limbs: Equatable, Sendable {
    var words: [UInt64]

    static let zero = Limbs(0)

    init(_ value: UInt64) { words = [value, 0, 0, 0] }

    init(words: [UInt64]) {
        precondition(words.count == 4)
        self.words = words
    }

    init(bigEndian bytes: some Collection<UInt8>) {
        let bytes = Array(bytes)
        precondition(bytes.count == 32)
        var words = [UInt64](repeating: 0, count: 4)
        for (index, byte) in bytes.enumerated() {
            let position = 31 - index
            words[position / 8] |= UInt64(byte) << UInt64((position % 8) * 8)
        }
        self.words = words
    }

    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bigEndian: bytes)
    }

    var bigEndianData: Data {
        var data = Data(count: 32)
        for position in 0..<32 {
            data[31 - position] = UInt8(truncatingIfNeeded: words[position / 8] >> UInt64((position % 8) * 8))
        }
        return data
    }

    var isZero: Bool { words.allSatisfy { $0 == 0 } }

    func bit(_ index: Int) -> Bool { (words[index / 64] >> UInt64(index % 64)) & 1 == 1 }

    static func < (a: Limbs, b: Limbs) -> Bool {
        for index in (0..<4).reversed() where a.words[index] != b.words[index] {
            return a.words[index] < b.words[index]
        }
        return false
    }

    func adding(_ other: Limbs) -> (sum: Limbs, carry: Bool) {
        var result = [UInt64](repeating: 0, count: 4)
        var carry: UInt64 = 0
        for index in 0..<4 {
            let (partial, overflow1) = words[index].addingReportingOverflow(other.words[index])
            let (sum, overflow2) = partial.addingReportingOverflow(carry)
            result[index] = sum
            carry = (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
        }
        return (Limbs(words: result), carry != 0)
    }

    func subtracting(_ other: Limbs) -> (difference: Limbs, borrow: Bool) {
        var result = [UInt64](repeating: 0, count: 4)
        var borrow: UInt64 = 0
        for index in 0..<4 {
            let (partial, overflow1) = words[index].subtractingReportingOverflow(other.words[index])
            let (difference, overflow2) = partial.subtractingReportingOverflow(borrow)
            result[index] = difference
            borrow = (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
        }
        return (Limbs(words: result), borrow != 0)
    }
}

/// Arithmetic modulo an odd 256-bit modulus, on numbers in Montgomery form
/// (a·R mod m, R = 2^256) unless a function says otherwise.
struct MontgomeryField: Sendable {
    let modulus: Limbs
    /// −m⁻¹ mod 2^64.
    private let inverseWord: UInt64
    private let rSquared: Limbs
    /// 1 in Montgomery form.
    let one: Limbs

    init(modulus: Limbs) {
        self.modulus = modulus
        var inverse: UInt64 = 1
        for _ in 0..<6 { inverse = inverse &* (2 &- modulus.words[0] &* inverse) }
        inverseWord = 0 &- inverse
        // 2^512 mod m, by doubling 1 512 times.
        var r = Limbs(1)
        for _ in 0..<512 {
            let (doubled, carry) = r.adding(r)
            r = carry || !(doubled < modulus) ? doubled.subtracting(modulus).difference : doubled
        }
        rSquared = r
        one = Self.montgomeryProduct(Limbs(1), r, modulus: modulus, inverseWord: inverseWord)
    }

    func add(_ a: Limbs, _ b: Limbs) -> Limbs {
        let (sum, carry) = a.adding(b)
        return carry || !(sum < modulus) ? sum.subtracting(modulus).difference : sum
    }

    func subtract(_ a: Limbs, _ b: Limbs) -> Limbs {
        let (difference, borrow) = a.subtracting(b)
        return borrow ? difference.adding(modulus).sum : difference
    }

    func multiply(_ a: Limbs, _ b: Limbs) -> Limbs {
        Self.montgomeryProduct(a, b, modulus: modulus, inverseWord: inverseWord)
    }

    func square(_ a: Limbs) -> Limbs { multiply(a, a) }

    /// From normal form (below the modulus).
    func toMontgomery(_ a: Limbs) -> Limbs { multiply(a, rSquared) }

    func fromMontgomery(_ a: Limbs) -> Limbs { multiply(a, Limbs(1)) }

    /// base^exponent, the exponent in normal form.
    func power(_ base: Limbs, exponent: Limbs) -> Limbs {
        var result = one
        for bit in (0..<256).reversed() {
            result = square(result)
            if exponent.bit(bit) { result = multiply(result, base) }
        }
        return result
    }

    /// a⁻¹, by Fermat (the modulus is prime).
    func inverse(_ a: Limbs) -> Limbs {
        power(a, exponent: modulus.subtracting(Limbs(2)).difference)
    }

    /// a·b·R⁻¹ mod m (CIOS).
    private static func montgomeryProduct(_ a: Limbs, _ b: Limbs, modulus m: Limbs, inverseWord: UInt64) -> Limbs {
        var t = [UInt64](repeating: 0, count: 6)
        for i in 0..<4 {
            var carry: UInt64 = 0
            for j in 0..<4 {
                let (high, low) = a.words[j].multipliedFullWidth(by: b.words[i])
                let (sum1, overflow1) = t[j].addingReportingOverflow(low)
                let (sum2, overflow2) = sum1.addingReportingOverflow(carry)
                t[j] = sum2
                carry = high &+ (overflow1 ? 1 : 0) &+ (overflow2 ? 1 : 0)
            }
            let (sum4, overflow4) = t[4].addingReportingOverflow(carry)
            t[4] = sum4
            t[5] = overflow4 ? 1 : 0

            let factor = t[0] &* inverseWord
            let (high0, low0) = factor.multipliedFullWidth(by: m.words[0])
            let (_, overflow0) = t[0].addingReportingOverflow(low0)
            carry = high0 &+ (overflow0 ? 1 : 0)
            for j in 1..<4 {
                let (high, low) = factor.multipliedFullWidth(by: m.words[j])
                let (sum1, overflow1) = t[j].addingReportingOverflow(low)
                let (sum2, overflow2) = sum1.addingReportingOverflow(carry)
                t[j - 1] = sum2
                carry = high &+ (overflow1 ? 1 : 0) &+ (overflow2 ? 1 : 0)
            }
            let (sum3, overflow3) = t[4].addingReportingOverflow(carry)
            t[3] = sum3
            t[4] = t[5] &+ (overflow3 ? 1 : 0)
        }
        let result = Limbs(words: Array(t[0..<4]))
        return t[4] != 0 || !(result < m) ? result.subtracting(m).difference : result
    }
}
