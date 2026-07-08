import BigInt
import CryptoKit
import Foundation

/// SRP-6a client (and a matching server, used by tests) for the HAP
/// Pair-Setup exchange.
///
/// Byte-for-byte port of nodeatv's `src/auth/srp.ts` (which itself mirrors
/// the `srptools` library pyatv relies on): RFC 5054 3072-bit group, SHA-512
/// hash, generator 5. The padding rules matter for byte-compatibility and are
/// reproduced exactly:
///
/// * `k = H(N | PAD(g))`, `u = H(PAD(A) | PAD(B))` -- operands padded to the
///   prime's byte length.
/// * `M1 = H(H(N) XOR H(g) | H(I) | salt | A | B | K)` and
///   `M2 = H(A | M1 | K)` -- here `A`/`B` use the *minimal* big-endian
///   encoding (no leading-zero padding), matching `bigintToBuffer`.
/// * `K = H(S)` with `S` in minimal big-endian encoding.
///
/// `BigInt` is confined to this file (per the task constraints); everything
/// downstream consumes plain `Data`.
public enum SRP {
    /// RFC 5054 3072-bit safe prime `N`.
    public static let prime: BigUInt = BigUInt(
        "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E08"
            + "8A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B"
            + "302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9"
            + "A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE6"
            + "49286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8"
            + "FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D"
            + "670C354E4ABC9804F1746C08CA18217C32905E462E36CE3BE39E772C"
            + "180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718"
            + "3995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D"
            + "04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7D"
            + "B3970F85A6E1E4C7ABF5AE8CDB0933D71E8C94E04A25619DCEE3D22"
            + "61AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200"
            + "CBBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BF"
            + "CE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF",
        radix: 16
    )!

    /// RFC 5054 generator for the 3072-bit group.
    public static let generator: BigUInt = 5

    // MARK: - Byte helpers (mirror srp.ts `bigintToBuffer` / `padToN`)

    /// Minimal big-endian encoding, matching JS `bigintToBuffer` (which emits
    /// a single `0x00` byte for zero rather than an empty buffer).
    static func bytes(_ value: BigUInt) -> Data {
        value.isZero ? Data([0]) : value.serialize()
    }

    /// Left-pad `value`'s minimal encoding with zeros to the prime's byte
    /// length, matching JS `padToN`.
    static func pad(_ value: BigUInt) -> Data {
        let primeLength = bytes(prime).count
        let raw = bytes(value)
        guard raw.count < primeLength else { return raw }
        return Data(repeating: 0, count: primeLength - raw.count) + raw
    }

    static func sha512(_ parts: Data...) -> Data {
        var hasher = SHA512()
        for part in parts { hasher.update(data: part) }
        return Data(hasher.finalize())
    }

    /// `k = H(N | PAD(g))`.
    static func computeK() -> BigUInt {
        BigUInt(sha512(bytes(prime), pad(generator)))
    }

    /// `u = H(PAD(A) | PAD(B))`.
    static func computeU(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        BigUInt(sha512(pad(a), pad(b)))
    }

    /// `x = H(salt | H(username ":" password))`.
    static func computeX(salt: Data, username: String, password: String) -> BigUInt {
        let identityHash = sha512(Data("\(username):\(password)".utf8))
        return BigUInt(sha512(salt, identityHash))
    }

    /// `M1 = H(H(N) XOR H(g) | H(I) | salt | A | B | K)`.
    static func clientProof(
        username: String, salt: Data, a: BigUInt, b: BigUInt, key: Data
    ) -> Data {
        let hN = sha512(bytes(prime))
        let hg = sha512(bytes(generator))
        var hNxorHg = Data(count: hN.count)
        for i in 0..<hN.count { hNxorHg[i] = hN[i] ^ hg[i] }
        let hI = sha512(Data(username.utf8))
        return sha512(hNxorHg, hI, salt, bytes(a), bytes(b), key)
    }

    /// `M2 = H(A | M1 | K)`.
    static func serverProof(a: BigUInt, clientProof m1: Data, key: Data) -> Data {
        sha512(bytes(a), m1, key)
    }
}

/// SRP context: the shared username/password and group parameters.
public struct SRPContext: Sendable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

/// Errors specific to the SRP math.
public enum SRPError: Error, Equatable, Sendable {
    /// Peer public key is congruent to 0 mod N.
    case invalidPublicKey
    /// Scrambling parameter `u` computed to zero.
    case zeroScramblingParameter
    /// `process()` has not been called yet.
    case notProcessed
}

/// SRP-6a client session.
public final class SRPClientSession {
    private let context: SRPContext
    private let privateKey: BigUInt
    private let publicValue: BigUInt

    private var sessionKeyValue: Data?
    private var clientProofValue: Data?

    /// - Parameter privateKey: the client's private exponent `a`. Injected for
    ///   deterministic tests; HAP feeds the controller's Ed25519 seed here,
    ///   exactly as pyatv/nodeatv do.
    public init(context: SRPContext, privateKey: Data) {
        self.context = context
        let a = BigUInt(privateKey)
        self.privateKey = a
        self.publicValue = SRP.generator.power(a, modulus: SRP.prime)
    }

    /// Client public key `A` (minimal big-endian).
    public var publicKey: Data { SRP.bytes(publicValue) }

    /// Session key `K` (SHA-512 of the shared secret `S`, 64 bytes).
    public var sessionKey: Data {
        get throws {
            guard let value = sessionKeyValue else { throw SRPError.notProcessed }
            return value
        }
    }

    /// Client proof `M1`.
    public var clientProof: Data {
        get throws {
            guard let value = clientProofValue else { throw SRPError.notProcessed }
            return value
        }
    }

    /// Process the server's public key `B` and `salt`, deriving `S`, `K`, `M1`.
    public func process(serverPublicKey: Data, salt: Data) throws {
        let b = BigUInt(serverPublicKey)
        if b % SRP.prime == 0 { throw SRPError.invalidPublicKey }

        let u = SRP.computeU(publicValue, b)
        if u == 0 { throw SRPError.zeroScramblingParameter }

        let k = SRP.computeK()
        let x = SRP.computeX(salt: salt, username: context.username, password: context.password)

        // S = (B - k * g^x) ^ (a + u * x) mod N
        let gx = SRP.generator.power(x, modulus: SRP.prime)
        let kgx = (k * gx) % SRP.prime
        let base = (b + SRP.prime - kgx) % SRP.prime
        let exponent = privateKey + u * x
        let s = base.power(exponent, modulus: SRP.prime)

        let key = SRP.sha512(SRP.bytes(s))
        self.sessionKeyValue = key
        self.clientProofValue = SRP.clientProof(
            username: context.username, salt: salt, a: publicValue, b: b, key: key
        )
    }

    /// Verify the server's proof `M2 = H(A | M1 | K)`.
    public func verifyProof(_ serverProof: Data) throws -> Bool {
        guard let key = sessionKeyValue, let m1 = clientProofValue else {
            throw SRPError.notProcessed
        }
        let expected = SRP.serverProof(a: publicValue, clientProof: m1, key: key)
        return expected == serverProof
    }
}

/// SRP-6a server session. Only used to drive the fake accessory in tests, but
/// kept in the shipping module so the SRP math has a single home.
public final class SRPServerSession {
    private let context: SRPContext
    private let privateKey: BigUInt
    private let publicValue: BigUInt
    private let saltValue: Data
    private let verifier: BigUInt

    private var sessionKeyValue: Data?
    private var serverProofValue: Data?

    /// - Parameters:
    ///   - privateKey: server private exponent `b` (injected for determinism).
    ///   - salt: pairing salt (injected for determinism; a device picks 16
    ///     random bytes).
    public init(context: SRPContext, privateKey: Data, salt: Data) {
        self.context = context
        let b = BigUInt(privateKey)
        self.privateKey = b
        self.saltValue = salt

        let x = SRP.computeX(salt: salt, username: context.username, password: context.password)
        let v = SRP.generator.power(x, modulus: SRP.prime)
        self.verifier = v

        let k = SRP.computeK()
        // B = (k * v + g^b) mod N
        self.publicValue = (k * v + SRP.generator.power(b, modulus: SRP.prime)) % SRP.prime
    }

    public var publicKey: Data { SRP.bytes(publicValue) }
    public var salt: Data { saltValue }

    public var sessionKey: Data {
        get throws {
            guard let value = sessionKeyValue else { throw SRPError.notProcessed }
            return value
        }
    }

    public var serverProof: Data {
        get throws {
            guard let value = serverProofValue else { throw SRPError.notProcessed }
            return value
        }
    }

    /// Process the client's public key and proof. Returns `true` (and computes
    /// `K`/`M2`) when the proof matches; `false` on a wrong PIN.
    public func processAndVerify(clientPublicKey: Data, clientProof: Data) throws -> Bool {
        let a = BigUInt(clientPublicKey)
        if a % SRP.prime == 0 { throw SRPError.invalidPublicKey }

        let u = SRP.computeU(a, publicValue)
        if u == 0 { throw SRPError.zeroScramblingParameter }

        // S = (A * v^u) ^ b mod N
        let vu = verifier.power(u, modulus: SRP.prime)
        let s = (a * vu % SRP.prime).power(privateKey, modulus: SRP.prime)

        let key = SRP.sha512(SRP.bytes(s))
        self.sessionKeyValue = key

        let expected = SRP.clientProof(
            username: context.username, salt: saltValue, a: a, b: publicValue, key: key
        )
        guard expected == clientProof else { return false }

        self.serverProofValue = SRP.serverProof(a: a, clientProof: expected, key: key)
        return true
    }
}
