import CryptoKit
import Foundation

/// HAP Pair-Verify (Companion flavor), M1 through M4.
///
/// Transport-agnostic like `PairSetup`: `m1()` returns the `_pd` blob to send,
/// `handleM2AndBuildM3(_:)` consumes the accessory's `_pd` blob and returns the
/// M3 blob. After a successful exchange the negotiated shared secret is
/// available via `deriveKey(salt:info:)` (Task 4 derives the per-direction
/// session keys from it).
///
/// Faithful port of pyatv `SRPAuthHandler.verify1`/`verify2` (`hap_srp.py`) +
/// `CompanionPairVerifyProcedure` (`companion/auth.py`).
public final class PairVerify {
    private let credentials: HAPCredentials
    private let verifyPrivate: Curve25519.KeyAgreement.PrivateKey
    /// Our ephemeral X25519 public key (32 bytes).
    private let publicBytes: Data

    private var shared: Data?

    /// - Parameters:
    ///   - credentials: the stored HAP credentials to authenticate against.
    ///   - verifyPrivateSeed: 32-byte X25519 ephemeral seed (injected for
    ///     deterministic tests); random if omitted.
    public init(credentials: HAPCredentials, verifyPrivateSeed: Data? = nil) {
        self.credentials = credentials
        if let seed = verifyPrivateSeed {
            self.verifyPrivate = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: seed)
        } else {
            self.verifyPrivate = Curve25519.KeyAgreement.PrivateKey()
        }
        self.publicBytes = verifyPrivate.publicKey.rawRepresentation
    }

    /// M1: send our ephemeral public key.
    public func m1() -> Data {
        TLV8.encode([
            (TLV8Tag.sequence, Data([0x01])),
            (TLV8Tag.publicKey, publicBytes),
        ])
    }

    /// M2 -> M3: perform ECDH, verify the accessory's signature against the
    /// stored `ltpk`, and return the M3 blob (our encrypted signature).
    public func handleM2AndBuildM3(_ data: Data) throws -> Data {
        let tlv = try PairingError.decode(data)
        let serverPubKey = try PairingError.require(tlv, .publicKey)
        let encrypted = try PairingError.require(tlv, .encryptedData)

        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverPubKey)
        let sharedSecret = try verifyPrivate.sharedSecretFromKeyAgreement(with: peer)
        let sharedData = sharedSecret.withUnsafeBytes { Data($0) }
        self.shared = sharedData

        let sessionKey = HAPCrypto.hkdf(
            salt: "Pair-Verify-Encrypt-Salt",
            info: "Pair-Verify-Encrypt-Info",
            sharedSecret: sharedData
        )

        let decrypted = try HAPCrypto.decrypt(encrypted, key: sessionKey, nonceLabel: "PV-Msg02")
        let decryptedTlv = TLV8.decode(decrypted)
        let identifier = try PairingError.require(decryptedTlv, .identifier)
        let signature = try PairingError.require(decryptedTlv, .signature)

        guard identifier == credentials.atvId else { throw PairingError.identifierMismatch }

        let info = serverPubKey + identifier + publicBytes
        let ltpk = try Curve25519.Signing.PublicKey(rawRepresentation: credentials.ltpk)
        guard ltpk.isValidSignature(signature, for: info) else {
            throw PairingError.signatureInvalid
        }

        let deviceInfo = publicBytes + credentials.clientId + serverPubKey
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: credentials.ltsk)
        let deviceSignature = try signingKey.signature(for: deviceInfo)

        let innerTlv = TLV8.encode([
            (TLV8Tag.identifier, credentials.clientId),
            (TLV8Tag.signature, Data(deviceSignature)),
        ])
        let responseEncrypted = try HAPCrypto.encrypt(
            innerTlv, key: sessionKey, nonceLabel: "PV-Msg03"
        )

        return TLV8.encode([
            (TLV8Tag.sequence, Data([0x03])),
            (TLV8Tag.encryptedData, responseEncrypted),
        ])
    }

    /// The negotiated X25519 shared secret. Available after a successful
    /// `handleM2AndBuildM3`.
    public var sharedSecret: Data {
        get throws {
            guard let shared else { throw PairingError.invalidState("shared secret not negotiated") }
            return shared
        }
    }

    /// Derive a session key from the shared secret, mirroring pyatv's
    /// `verify2`. Task 4 calls this with the Companion connection's
    /// salt/info strings for each direction.
    public func deriveKey(salt: String, info: String) throws -> SymmetricKey {
        let shared = try sharedSecret
        return SymmetricKey(data: HAPCrypto.hkdf(salt: salt, info: info, sharedSecret: shared))
    }
}
