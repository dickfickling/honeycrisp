import CryptoKit
import Foundation
@testable import CompanionKit

/// Fake Apple TV accessory driving the accessory side of Pair-Setup and
/// Pair-Verify, for end-to-end tests. Port of nodeatv's
/// `CompanionServerAuth` (`src/protocols/companion/serverAuth.ts`) +
/// `serverAuth.ts` helpers, using CryptoKit and the ported `SRPServerSession`.
///
/// All randomness is injectable so full flows are deterministic.
final class FakeCompanionServer {
    static let serverId = Data("CompanionServerAuth".utf8)

    let pin: Int
    let signingKey: Curve25519.Signing.PrivateKey
    let ed25519PublicKey: Data

    private let srpPrivate: Data
    private let srpSalt: Data
    private var srp: SRPServerSession?

    private let verifySeed: Data
    private var verifyShared: Data?

    init(
        pin: Int = 1111,
        edSeed: Data,
        srpPrivate: Data,
        srpSalt: Data,
        verifySeed: Data
    ) {
        self.pin = pin
        self.signingKey = try! Curve25519.Signing.PrivateKey(rawRepresentation: edSeed)
        self.ed25519PublicKey = signingKey.publicKey.rawRepresentation
        self.srpPrivate = srpPrivate
        self.srpSalt = srpSalt
        self.verifySeed = verifySeed
    }

    // MARK: - Pair-Setup

    func handlePairSetup(_ data: Data) throws -> Data {
        let tlv = TLV8.decode(data)
        switch tlv[TLV8Tag.sequence.rawValue]?.first {
        case 0x01: return pairSetupM2()
        case 0x03: return try pairSetupM4(tlv)
        case 0x05: return try pairSetupM6(tlv)
        default: fatalError("unexpected pair-setup seqno")
        }
    }

    private func pairSetupM2() -> Data {
        let session = SRPServerSession(
            context: SRPContext(username: "Pair-Setup", password: String(pin)),
            privateKey: srpPrivate,
            salt: srpSalt
        )
        self.srp = session
        return TLV8.encode([
            (TLV8Tag.sequence, Data([0x02])),
            (TLV8Tag.salt, session.salt),
            (TLV8Tag.publicKey, session.publicKey),
        ])
    }

    private func pairSetupM4(_ tlv: [UInt8: Data]) throws -> Data {
        let session = srp!
        let clientPub = tlv[TLV8Tag.publicKey.rawValue]!
        let clientProof = tlv[TLV8Tag.proof.rawValue]!
        let verified = try session.processAndVerify(
            clientPublicKey: clientPub, clientProof: clientProof)
        if !verified {
            return TLV8.encode([
                (TLV8Tag.sequence, Data([0x04])),
                (TLV8Tag.error, Data([0x02])),
            ])
        }
        return TLV8.encode([
            (TLV8Tag.sequence, Data([0x04])),
            (TLV8Tag.proof, try session.serverProof),
        ])
    }

    private func pairSetupM6(_ tlv: [UInt8: Data]) throws -> Data {
        let sessionKey = try srp!.sessionKey
        let encryptKey = HAPCrypto.hkdf(
            salt: "Pair-Setup-Encrypt-Salt",
            info: "Pair-Setup-Encrypt-Info",
            sharedSecret: sessionKey
        )
        _ = try HAPCrypto.decrypt(
            tlv[TLV8Tag.encryptedData.rawValue]!, key: encryptKey, nonceLabel: "PS-Msg05")

        let signKey = HAPCrypto.hkdf(
            salt: "Pair-Setup-Accessory-Sign-Salt",
            info: "Pair-Setup-Accessory-Sign-Info",
            sharedSecret: sessionKey
        )
        let serverInfo = signKey + Self.serverId + ed25519PublicKey
        let signature = Data(try signingKey.signature(for: serverInfo))

        let responseTlv = TLV8.encode([
            (TLV8Tag.identifier, Self.serverId),
            (TLV8Tag.publicKey, ed25519PublicKey),
            (TLV8Tag.signature, signature),
        ])
        let encrypted = try HAPCrypto.encrypt(
            responseTlv, key: encryptKey, nonceLabel: "PS-Msg06")

        return TLV8.encode([
            (TLV8Tag.sequence, Data([0x06])),
            (TLV8Tag.encryptedData, encrypted),
        ])
    }

    // MARK: - Pair-Verify

    /// Set to `true` to corrupt the accessory's signature in V2 (tamper test).
    var tamperSignature = false

    func handlePairVerify(_ data: Data) throws -> Data {
        let tlv = TLV8.decode(data)
        switch tlv[TLV8Tag.sequence.rawValue]?.first {
        case 0x01: return try pairVerifyM2(tlv)
        case 0x03: return try pairVerifyM4(tlv)
        default: fatalError("unexpected pair-verify seqno")
        }
    }

    private func pairVerifyM2(_ tlv: [UInt8: Data]) throws -> Data {
        let clientPub = tlv[TLV8Tag.publicKey.rawValue]!

        let priv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: verifySeed)
        let serverPub = priv.publicKey.rawRepresentation
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientPub)
        let shared = try priv.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Data($0) }
        self.verifyShared = shared

        let sessionKey = HAPCrypto.hkdf(
            salt: "Pair-Verify-Encrypt-Salt",
            info: "Pair-Verify-Encrypt-Info",
            sharedSecret: shared
        )

        let deviceInfo = serverPub + Self.serverId + clientPub
        var signature = Data(try signingKey.signature(for: deviceInfo))
        if tamperSignature { signature[0] ^= 0xFF }

        let innerTlv = TLV8.encode([
            (TLV8Tag.identifier, Self.serverId),
            (TLV8Tag.signature, signature),
        ])
        let encrypted = try HAPCrypto.encrypt(innerTlv, key: sessionKey, nonceLabel: "PV-Msg02")

        return TLV8.encode([
            (TLV8Tag.sequence, Data([0x02])),
            (TLV8Tag.publicKey, serverPub),
            (TLV8Tag.encryptedData, encrypted),
        ])
    }

    private(set) var outputKey: SymmetricKey?
    private(set) var inputKey: SymmetricKey?

    private func pairVerifyM4(_ tlv: [UInt8: Data]) throws -> Data {
        let shared = verifyShared!
        let sessionKey = HAPCrypto.hkdf(
            salt: "Pair-Verify-Encrypt-Salt",
            info: "Pair-Verify-Encrypt-Info",
            sharedSecret: shared
        )
        _ = try HAPCrypto.decrypt(
            tlv[TLV8Tag.encryptedData.rawValue]!, key: sessionKey, nonceLabel: "PV-Msg03")

        outputKey = SymmetricKey(data: HAPCrypto.hkdf(
            salt: "MediaRemote-Salt", info: "MediaRemote-Write-Encryption-Key",
            sharedSecret: shared))
        inputKey = SymmetricKey(data: HAPCrypto.hkdf(
            salt: "MediaRemote-Salt", info: "MediaRemote-Read-Encryption-Key",
            sharedSecret: shared))

        return TLV8.encode([(TLV8Tag.sequence, Data([0x04]))])
    }

    // MARK: - Companion session keys (Task 4)

    /// Derive the Companion per-frame ChaCha20 keys from the verified shared
    /// secret, matching pyatv's `SRP_SALT`/`ClientEncrypt-main`/
    /// `ServerEncrypt-main`. `client` is the key the client encrypts with
    /// (the server decrypts inbound frames with it); `server` is the key the
    /// server encrypts with. Must be called after `pairVerifyM4`.
    func companionSessionKeys() throws -> (client: Data, server: Data) {
        guard let shared = verifyShared else {
            throw PairingError.invalidState("verify not completed")
        }
        let client = HAPCrypto.hkdf(
            salt: "", info: "ClientEncrypt-main", sharedSecret: shared)
        let server = HAPCrypto.hkdf(
            salt: "", info: "ServerEncrypt-main", sharedSecret: shared)
        return (client, server)
    }
}
