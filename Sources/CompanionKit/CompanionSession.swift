import CryptoKit
import Foundation

/// Per-frame ChaCha20-Poly1305 encryption state for an established Companion
/// session.
///
/// Faithful port of pyatv's `chacha20.Chacha20Cipher` as instantiated by
/// `connection.py`'s `enable_encryption`, which uses `nonce_length=12`:
///
/// - Two independent keys, one per direction (`out` = data we send, `in` =
///   data we receive), each with its own monotonically-incrementing counter.
/// - The nonce is the counter encoded as a 12-byte little-endian integer
///   (equivalently: the 8-byte little-endian counter with four high zero
///   bytes). This matches `counter.to_bytes(12, "little")`.
/// - Each direction's counter increments by one per frame, mirroring pyatv
///   consuming the nonce and then advancing the counter.
/// - Output is `ciphertext || 16-byte Poly1305 tag`, matching
///   python-cryptography / node's combined output.
///
/// Errors are surfaced via `PairingError.decryptionFailed` (shared with the
/// pairing layer) so callers have a single crypto-failure type.
final class CompanionSession {
    private let outKey: SymmetricKey
    private let inKey: SymmetricKey
    private var outCounter: UInt64 = 0
    private var inCounter: UInt64 = 0

    /// - Parameters:
    ///   - outputKey: key used to encrypt outbound frames
    ///     (pyatv `output_key`, HKDF info `ClientEncrypt-main`).
    ///   - inputKey: key used to decrypt inbound frames
    ///     (pyatv `input_key`, HKDF info `ServerEncrypt-main`).
    init(outputKey: Data, inputKey: Data) {
        self.outKey = SymmetricKey(data: outputKey)
        self.inKey = SymmetricKey(data: inputKey)
    }

    init(outputKey: SymmetricKey, inputKey: SymmetricKey) {
        self.outKey = outputKey
        self.inKey = inputKey
    }

    /// 12-byte little-endian nonce for the given counter value.
    static func nonce(_ counter: UInt64) -> Data {
        var data = Data(count: 12)
        withUnsafeBytes(of: counter.littleEndian) { raw in
            for i in 0 ..< 8 { data[i] = raw[i] }
        }
        return data
    }

    /// Encrypt one outbound frame payload, authenticating `aad` (the 4-byte
    /// frame header), and advance the outbound counter.
    ///
    /// - Returns: `ciphertext || tag`.
    func encrypt(_ plaintext: Data, aad: Data) throws -> Data {
        let nonceData = Self.nonce(outCounter)
        outCounter &+= 1
        do {
            let box = try ChaChaPoly.seal(
                plaintext,
                using: outKey,
                nonce: try ChaChaPoly.Nonce(data: nonceData),
                authenticating: aad
            )
            return box.ciphertext + box.tag
        } catch {
            throw PairingError.decryptionFailed
        }
    }

    /// Decrypt one inbound frame payload (`ciphertext || tag`), authenticating
    /// `aad` (the 4-byte frame header), and advance the inbound counter.
    func decrypt(_ combined: Data, aad: Data) throws -> Data {
        guard combined.count >= 16 else { throw PairingError.decryptionFailed }
        let nonceData = Self.nonce(inCounter)
        inCounter &+= 1
        let tag = combined.suffix(16)
        let ciphertext = combined.prefix(combined.count - 16)
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: try ChaChaPoly.Nonce(data: nonceData),
                ciphertext: ciphertext,
                tag: tag
            )
            return try ChaChaPoly.open(box, using: inKey, authenticating: aad)
        } catch {
            throw PairingError.decryptionFailed
        }
    }
}
