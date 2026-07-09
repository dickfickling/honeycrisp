import CryptoKit
import Foundation

/// Errors surfaced by the HAP Pair-Setup / Pair-Verify state machines.
public enum PairingError: Error, Equatable, Sendable {
    /// A required TLV field was absent from a device response.
    case missingField(TLV8Tag)
    /// The device returned a TLV `Error` field with this code (e.g. `0x02`
    /// "authentication" on a wrong PIN).
    case deviceError(UInt8)
    /// The server's SRP proof did not verify.
    case proofMismatch
    /// The device identifier did not match the stored credentials.
    case identifierMismatch
    /// The device's Ed25519 signature failed to verify.
    case signatureInvalid
    /// ChaCha20-Poly1305 authentication failed while decrypting.
    case decryptionFailed
    /// A step was invoked out of order.
    case invalidState(String)
}

/// HAP crypto primitives shared by Pair-Setup and Pair-Verify, matching
/// pyatv's `hkdf_expand` and `Chacha20Cipher8byteNonce`.
enum HAPCrypto {
    /// HKDF-SHA512 to a 32-byte key. `salt`/`info` are the UTF-8 bytes of the
    /// HAP salt/info *strings* (e.g. "Pair-Setup-Encrypt-Salt").
    static func hkdf(salt: String, info: String, sharedSecret: Data) -> Data {
        let key = HKDF<SHA512>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedSecret),
            salt: Data(salt.utf8),
            info: Data(info.utf8),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    /// Build the 12-byte nonce from an 8-byte HAP nonce string: four zero
    /// bytes followed by the string, matching `Chacha20Cipher8byteNonce`'s
    /// `_pad_nonce`.
    private static func nonce(_ label: String) -> Data {
        Data(count: 4) + Data(label.utf8)
    }

    /// ChaCha20-Poly1305 encrypt; returns ciphertext || 16-byte tag, matching
    /// python-cryptography's combined output.
    static func encrypt(_ plaintext: Data, key: Data, nonceLabel: String) throws -> Data {
        let box = try ChaChaPoly.seal(
            plaintext,
            using: SymmetricKey(data: key),
            nonce: try ChaChaPoly.Nonce(data: nonce(nonceLabel))
        )
        return box.ciphertext + box.tag
    }

    /// ChaCha20-Poly1305 decrypt of ciphertext || 16-byte tag.
    static func decrypt(_ combined: Data, key: Data, nonceLabel: String) throws -> Data {
        guard combined.count >= 16 else { throw PairingError.decryptionFailed }
        let tag = combined.suffix(16)
        let ciphertext = combined.prefix(combined.count - 16)
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: try ChaChaPoly.Nonce(data: nonce(nonceLabel)),
                ciphertext: ciphertext,
                tag: tag
            )
            return try ChaChaPoly.open(box, using: SymmetricKey(data: key))
        } catch {
            throw PairingError.decryptionFailed
        }
    }

    /// 32 cryptographically-random bytes.
    static func randomBytes(_ count: Int) -> Data {
        SymmetricKey(size: .init(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }
}

extension PairingError {
    /// Decode a TLV response and raise `.deviceError` if it carries an error
    /// field, mirroring pyatv's `_get_pairing_data`.
    static func decode(_ data: Data) throws -> [UInt8: Data] {
        let tlv = TLV8.decode(data)
        if let error = tlv[TLV8Tag.error.rawValue], let code = error.first {
            throw PairingError.deviceError(code)
        }
        return tlv
    }

    static func require(_ tlv: [UInt8: Data], _ tag: TLV8Tag) throws -> Data {
        guard let value = tlv[tag.rawValue] else { throw PairingError.missingField(tag) }
        return value
    }
}

/// HAP Pair-Setup (Companion flavor), M1 through M6.
///
/// Transport-agnostic: every `mN()` returns the `_pd` pairing-data TLV blob to
/// send, and every `handleMN(_:)` consumes the `_pd` blob received. The
/// Companion OPACK frame wrapping happens in the connection layer (Task 4).
///
/// Faithful port of pyatv `SRPAuthHandler` (`hap_srp.py`) +
/// `CompanionPairSetupProcedure` (`companion/auth.py`).
public final class PairSetup {
    private let username: String
    private let pin: Int
    private let displayName: String?

    /// The controller's Ed25519 seed. This doubles as the SRP private key `a`
    /// (as in pyatv/nodeatv) and becomes the credentials' `ltsk`.
    private let signingSeed: Data
    private let signingKey: Curve25519.Signing.PrivateKey
    private let authPublic: Data

    /// The controller identifier (`client_id`); a UUID string's UTF-8 bytes.
    public let pairingId: Data

    private var session: SRPClientSession?

    /// - Parameters:
    ///   - pin: the PIN shown on screen. Zero-padded to 4 digits to match
    ///     pyatv's `str(pin).zfill(4)` (companion/pairing.py:77) — without the
    ///     padding, any PIN with a leading zero could never pair.
    ///   - signingSeed: 32-byte Ed25519 seed (injected for deterministic
    ///     tests); random if omitted.
    ///   - pairingId: controller identifier bytes; a random UUID if omitted.
    public init(
        username: String = "Pair-Setup",
        pin: Int,
        displayName: String? = nil,
        signingSeed: Data? = nil,
        pairingId: Data? = nil
    ) {
        self.username = username
        self.pin = pin
        self.displayName = displayName
        let seed = signingSeed ?? HAPCrypto.randomBytes(32)
        self.signingSeed = seed
        // rawRepresentation of a CryptoKit Ed25519 private key *is* the seed,
        // so `signingSeed == auth_private` exactly as in the references.
        self.signingKey = try! Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        self.authPublic = signingKey.publicKey.rawRepresentation
        self.pairingId = pairingId ?? Data(UUID().uuidString.utf8)
    }

    /// M1: request the salt and the accessory's SRP public key.
    public func m1() -> Data {
        TLV8.encode([
            (TLV8Tag.method, Data([0x00])),
            (TLV8Tag.sequence, Data([0x01])),
        ])
    }

    /// M2 -> M3: consume the accessory's salt + public key, run the SRP
    /// exchange, and return the M3 blob (client public key + proof).
    public func handleM2AndBuildM3(_ data: Data) throws -> Data {
        let tlv = try PairingError.decode(data)
        let salt = try PairingError.require(tlv, .salt)
        let atvPubKey = try PairingError.require(tlv, .publicKey)

        let context = SRPContext(username: username, password: String(format: "%04d", pin))
        let session = SRPClientSession(context: context, privateKey: signingSeed)
        try session.process(serverPublicKey: atvPubKey, salt: salt)
        self.session = session

        return TLV8.encode([
            (TLV8Tag.sequence, Data([0x03])),
            (TLV8Tag.publicKey, session.publicKey),
            (TLV8Tag.proof, try session.clientProof),
        ])
    }

    /// M4 -> M5: verify the accessory's proof (raising on a wrong PIN), then
    /// return the M5 blob (encrypted controller device info).
    public func handleM4AndBuildM5(_ data: Data) throws -> Data {
        guard let session else { throw PairingError.invalidState("handleM4 before handleM2") }
        let tlv = try PairingError.decode(data)

        // pyatv does not verify the accessory proof here; nodeatv's companion
        // procedure does. We follow nodeatv (a real MITM check) -- it is a
        // pure check and does not change any bytes sent on the wire.
        if let proof = tlv[TLV8Tag.proof.rawValue] {
            guard try session.verifyProof(proof) else { throw PairingError.proofMismatch }
        }

        let sessionKey = try session.sessionKey
        let iosDeviceX = HAPCrypto.hkdf(
            salt: "Pair-Setup-Controller-Sign-Salt",
            info: "Pair-Setup-Controller-Sign-Info",
            sharedSecret: sessionKey
        )
        let encryptKey = HAPCrypto.hkdf(
            salt: "Pair-Setup-Encrypt-Salt",
            info: "Pair-Setup-Encrypt-Info",
            sharedSecret: sessionKey
        )

        let deviceInfo = iosDeviceX + pairingId + authPublic
        let signature = try signingKey.signature(for: deviceInfo)

        var inner: [(tag: TLV8Tag, value: Data)] = [
            (.identifier, pairingId),
            (.publicKey, authPublic),
            (.signature, Data(signature)),
        ]
        if let displayName {
            inner.append((.name, try OPACK.pack(.dictionary([(.string("name"), .string(displayName))]))))
        }

        let encrypted = try HAPCrypto.encrypt(
            TLV8.encode(inner), key: encryptKey, nonceLabel: "PS-Msg05"
        )

        return TLV8.encode([
            (TLV8Tag.sequence, Data([0x05])),
            (TLV8Tag.encryptedData, encrypted),
        ])
    }

    /// M6: decrypt the accessory's device info and build the resulting
    /// credentials. `ltpk` is the accessory's Ed25519 public key, `ltsk` is the
    /// controller's own signing seed, exactly as pyatv's `step4` builds them.
    public func handleM6(_ data: Data) throws -> HAPCredentials {
        guard let session else { throw PairingError.invalidState("handleM6 before handleM2") }
        let tlv = try PairingError.decode(data)
        let encrypted = try PairingError.require(tlv, .encryptedData)

        let decryptKey = HAPCrypto.hkdf(
            salt: "Pair-Setup-Encrypt-Salt",
            info: "Pair-Setup-Encrypt-Info",
            sharedSecret: try session.sessionKey
        )
        let decrypted = try HAPCrypto.decrypt(encrypted, key: decryptKey, nonceLabel: "PS-Msg06")

        let inner = TLV8.decode(decrypted)
        let atvId = try PairingError.require(inner, .identifier)
        let atvPubKey = try PairingError.require(inner, .publicKey)
        // The accessory signature (inner[.signature]) is present but, matching
        // pyatv's `step4` ("TODO: verify signature here"), not verified.

        return HAPCredentials(
            ltpk: atvPubKey,
            ltsk: signingSeed,
            atvId: atvId,
            clientId: pairingId
        )
    }
}
