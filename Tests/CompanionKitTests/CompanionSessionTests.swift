import CryptoKit
import Foundation
import Testing
@testable import CompanionKit

/// Per-frame ChaCha20-Poly1305 tests. Vectors were generated with the same
/// crypto primitive nodeatv/pyatv use (node `chacha20-poly1305` / python
/// `cryptography`), driving the Companion `enable_encryption` path
/// (`nonce_length = 12`, 4-byte header as AAD, `ciphertext || 16-byte tag`).
struct CompanionSessionTests {
    // 'k' * 32, as in nodeatv chacha20.test.ts.
    static let key = Data(repeating: 0x6B, count: 32)

    @Test func nonceIsTwelveByteLittleEndianCounter() {
        #expect(CompanionSession.nonce(0) == Data(count: 12))
        #expect(CompanionSession.nonce(1) == hexData("01 00 00 00 00 00 00 00 00 00 00 00"))
        #expect(CompanionSession.nonce(258) == hexData("02 01 00 00 00 00 00 00 00 00 00 00"))
    }

    @Test func encryptMatchesReferenceVector() throws {
        let session = CompanionSession(outputKey: Self.key, inputKey: Self.key)
        // E_OPACK, plaintext "test", header length = 4 + 16 tag = 0x14.
        let header = hexData("08 00 00 14")
        let ciphertext = try session.encrypt(Data("test".utf8), aad: header)
        #expect(ciphertext == hexData("def1c683c7247d3ab95088b75f4a88d71f209c5e"))
    }

    @Test func encryptCounterProgressionMatchesReference() throws {
        let session = CompanionSession(outputKey: Self.key, inputKey: Self.key)
        // First frame consumes counter 0.
        let ct0 = try session.encrypt(Data("test".utf8), aad: hexData("08 00 00 14"))
        #expect(ct0 == hexData("def1c683c7247d3ab95088b75f4a88d71f209c5e"))
        // Second frame consumes counter 1 (11 bytes + 16 tag = 0x1b).
        let ct1 = try session.encrypt(Data("hello world".utf8), aad: hexData("08 00 00 1b"))
        #expect(ct1 == hexData("465e3cce2deff58ab0709ebf9b3e20d8bf4b0a7c3af4aa82910705"))
    }

    @Test func decryptReversesReferenceVector() throws {
        let session = CompanionSession(outputKey: Self.key, inputKey: Self.key)
        let plaintext = try session.decrypt(
            hexData("def1c683c7247d3ab95088b75f4a88d71f209c5e"),
            aad: hexData("08 00 00 14"))
        #expect(plaintext == Data("test".utf8))
    }

    @Test func roundTripAcrossDirections() throws {
        // A -> B uses A.out / B.in; distinct keys per direction.
        let outKey = Data(repeating: 0x01, count: 32)
        let inKey = Data(repeating: 0x02, count: 32)
        let client = CompanionSession(outputKey: outKey, inputKey: inKey)
        let server = CompanionSession(outputKey: inKey, inputKey: outKey)

        let header1 = try CompanionFraming.header(typeByte: 8, payloadLength: 5 + 16)
        let c1 = try client.encrypt(Data("hello".utf8), aad: header1)
        #expect(try server.decrypt(c1, aad: header1) == Data("hello".utf8))

        let header2 = try CompanionFraming.header(typeByte: 8, payloadLength: 5 + 16)
        let s1 = try server.encrypt(Data("world".utf8), aad: header2)
        #expect(try client.decrypt(s1, aad: header2) == Data("world".utf8))
    }

    @Test func decryptWithWrongAADFails() throws {
        let session = CompanionSession(outputKey: Self.key, inputKey: Self.key)
        let ct = try session.encrypt(Data("test".utf8), aad: hexData("08 00 00 14"))
        let fresh = CompanionSession(outputKey: Self.key, inputKey: Self.key)
        #expect(throws: PairingError.decryptionFailed) {
            _ = try fresh.decrypt(ct, aad: hexData("07 00 00 14")) // wrong type byte
        }
    }
}
