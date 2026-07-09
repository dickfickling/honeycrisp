import CryptoKit
import Foundation
import Testing
@testable import CompanionKit

/// End-to-end HAP Pair-Setup / Pair-Verify tests driven against the fake
/// Companion accessory, mirroring nodeatv's
/// `tests/protocols/companion/serverAuth.test.ts`.
struct PairingTests {
    // Deterministic seeds.
    static let clientSeed = Data(repeating: 0x42, count: 32)       // Ed25519 + SRP `a`
    static let pairingId = Data("11111111-2222-3333-4444-555555555555".utf8)
    static let serverEdSeed = Data(repeating: 0x33, count: 32)
    static let serverSrpPrivate = Data(repeating: 0x11, count: 32)
    static let serverSalt = Data(repeating: 0x01, count: 16)
    static let serverVerifySeed = Data(repeating: 0x55, count: 32)

    /// Server Ed25519 public key for `serverEdSeed` (0x33 x 32), computed with
    /// the reference (node crypto). This is the expected credential `ltpk`.
    static let expectedServerLtpk = hexData(
        "17cb79fb2b4120f2b1ec65e4198d6e08b28e813feb01e4a400839b85e18080ce")

    private func makeServer(pin: Int = 1111) -> FakeCompanionServer {
        FakeCompanionServer(
            pin: pin,
            edSeed: Self.serverEdSeed,
            srpPrivate: Self.serverSrpPrivate,
            srpSalt: Self.serverSalt,
            verifySeed: Self.serverVerifySeed
        )
    }

    private func runSetup(
        clientPin: Int = 1111, serverPin: Int = 1111
    ) throws -> HAPCredentials {
        let server = makeServer(pin: serverPin)
        let setup = PairSetup(
            pin: clientPin,
            signingSeed: Self.clientSeed,
            pairingId: Self.pairingId
        )

        let m1 = setup.m1()
        let m2 = try server.handlePairSetup(m1)
        let m3 = try setup.handleM2AndBuildM3(m2)
        let m4 = try server.handlePairSetup(m3)
        let m5 = try setup.handleM4AndBuildM5(m4)
        let m6 = try server.handlePairSetup(m5)
        return try setup.handleM6(m6)
    }

    @Test func pairSetupProducesKnownCredentials() throws {
        let credentials = try runSetup()
        #expect(credentials.ltpk == Self.expectedServerLtpk)
        #expect(credentials.ltsk == Self.clientSeed)
        #expect(credentials.atvId == FakeCompanionServer.serverId)
        #expect(credentials.clientId == Self.pairingId)
    }

    @Test func m1BlobMatchesReference() {
        let setup = PairSetup(pin: 1111, signingSeed: Self.clientSeed, pairingId: Self.pairingId)
        // pyatv: write_tlv({Method: 0x00, SeqNo: 0x01})
        #expect(setup.m1() == hexData("0001 00 0601 01"))
    }

    @Test func wrongPinThrowsDeviceError() throws {
        // Client uses 9999, accessory expects 1111 -> proof mismatch -> the
        // accessory returns TLV Error 0x02 at M4, surfaced as .deviceError.
        #expect(throws: PairingError.deviceError(0x02)) {
            _ = try runSetup(clientPin: 9999, serverPin: 1111)
        }
    }

    @Test func leadingZeroPinPairs() throws {
        // The SRP password must be zero-padded to 4 digits (pyatv zfill(4)):
        // PIN 0472 as Int 472 formatted "472" would never match the device's
        // "0472" proof. Both sides derive the password from the Int, so this
        // only passes if both pad identically.
        let credentials = try runSetup(clientPin: 472, serverPin: 472)
        #expect(credentials.ltpk == Self.expectedServerLtpk)
    }

    @Test func pairVerifyDerivesMatchingSessionKeys() throws {
        let credentials = try runSetup()
        let server = makeServer()
        // Prime the accessory's verify side by running setup on it too (so its
        // Ed25519 identity is the one credentials were minted against). We
        // reuse the same seeds, so a fresh server instance is equivalent.

        let verify = PairVerify(
            credentials: credentials, verifyPrivateSeed: Data(repeating: 0x77, count: 32))

        let v1 = verify.m1()
        let v2 = try server.handlePairVerify(v1)
        let v3 = try verify.handleM2AndBuildM3(v2)
        let v4 = try server.handlePairVerify(v3)
        #expect(TLV8.decode(v4)[TLV8Tag.sequence.rawValue]?.first == 0x04)

        // Both sides derive the same directional keys from the shared secret.
        let clientWrite = try verify.deriveKey(
            salt: "MediaRemote-Salt", info: "MediaRemote-Write-Encryption-Key")
        let clientRead = try verify.deriveKey(
            salt: "MediaRemote-Salt", info: "MediaRemote-Read-Encryption-Key")

        #expect(clientWrite == server.outputKey)
        #expect(clientRead == server.inputKey)
    }

    @Test func tamperedAccessorySignatureFailsVerify() throws {
        let credentials = try runSetup()
        let server = makeServer()
        server.tamperSignature = true

        let verify = PairVerify(
            credentials: credentials, verifyPrivateSeed: Data(repeating: 0x77, count: 32))
        let v1 = verify.m1()
        let v2 = try server.handlePairVerify(v1)
        #expect(throws: PairingError.signatureInvalid) {
            _ = try verify.handleM2AndBuildM3(v2)
        }
    }

    @Test func wrongCredentialsIdentifierFailsVerify() throws {
        let credentials = try runSetup()
        var tampered = credentials
        tampered.atvId = Data("not-the-server".utf8)

        let server = makeServer()
        let verify = PairVerify(
            credentials: tampered, verifyPrivateSeed: Data(repeating: 0x77, count: 32))
        let v1 = verify.m1()
        let v2 = try server.handlePairVerify(v1)
        #expect(throws: PairingError.identifierMismatch) {
            _ = try verify.handleM2AndBuildM3(v2)
        }
    }
}
