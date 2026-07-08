import Foundation
import Testing
@testable import CompanionKit

/// SRP-6a math tests.
///
/// The fixed-input vectors are generated from the reference SRP math
/// (nodeatv `src/auth/srp.ts`, which mirrors the `srptools` library pyatv
/// uses) with deterministic inputs, giving a byte-exact cross-check:
///   username = "Pair-Setup", password = "1111"
///   client `a` = 32 x 0x42, server `b` = 32 x 0x11, salt = 16 x 0x01
struct SRPTests {
    static let username = "Pair-Setup"
    static let password = "1111"
    static let clientPrivate = Data(repeating: 0x42, count: 32)
    static let serverPrivate = Data(repeating: 0x11, count: 32)
    static let salt = Data(repeating: 0x01, count: 16)

    // Expected values (see file header for provenance).
    static let expectedA = hexData(
        "d11f6d69a669d59747c46e76bdfb2de0ecd59ed1fdadbad3ddf57896334611e1d30dfc247303598e12b7aaad03dff318ac23c84383bfa54472b72abba7d0dde22d9aa6180caf06d0b64d47f3b84838e4b3d18d39dd07e5185acb343c18cb52a26c66d2995b0f3891ee2b8c86b5a68c5b9c19a0c248eeb8448b7530fa6151441ca174e6f35b665fa7bbd9c90f817bc31ffda302026b5a70380a766e63c4134afde0648a5df8f8ace674c1a8e248ebc135d54ec580d120437930398a474d1d382aff31e109d65ff6b73f659d4066673dd439ec35d28844d3d8b2564d750772b00a106973dae1ad8e8cfbdecd5436dd04df3b24fad69d48b9afca4dbd2e10ae2417e7c37d660a9f3bfc8972237a79eb254e3bf0d9b0e2d8e9f37ca9c8725e538ada6b88ae0aa56c0f44c24d96c6ba0c19e9e83782eafca461d493d1cb98c8f59da20f9c16e4ad579fbafed273d97e5810585b89bbd9486bee0c37933947c02e6d4844e13d966322bf91037678d02d32fe14782013036ff4a54b706ef0ce84f966c5")
    static let expectedB = hexData(
        "7c7c1942f9d2e7e831daaca57f7be6226370ba8936ddad178fc455f6bcda43aeb651f30255333dca96326255c0aa96067a1a823890cdfbe450039080777fbe7c07dbdec1d7d82c477720fb295c2c2a90e043877f9175c500f35896d4dcf6cea7adea48fc98b283e4092fd0670e758148c04b3b703899dba65d7173ff38292ffafbc60895fa26df0e2e7b1563a1e43054ce218bf8959b368f0e70efc6c9765bc6273523ce11a40e9b8827ef5edfd0db39cca54d16810e9a2088af7ee39fe44d28613f63f034bb7b6ef2ba905f310b106b87fc147cd5bee98b2fb5d5b0a9e67531263c646a5ed4228bdd267554a776b6c9e806f3bfbb4b7a61eecf972af5ae0b74ed7154a2c0e4b8e8510e591c7a4560cfc4466269ec02f8154a1a8ee97c835c9c9b5573a567717dcfa36911714bb817325ae2543fe078eaee5cb0dfd3df4fc3765fc533c32a66b87fe9edf9a8e109a0540fec9a1d3c5b1852d4227917d9ea75c43755a461467aaae9edbbd2ec7f71671ea41ae11bd2fb987a5668684469fa3b5c")
    static let expectedK = hexData(
        "fe71e1988073f8d72d6967a2ecf817f070a05419194410a706305bc033ab9a92ed6feddff05b0131af3574d3ec32d0da80f3db7cfa767081845e3ad57edf7edb")
    static let expectedM1 = hexData(
        "724f0f3733fed68bf8ae9195aaf9c953849a2d27eebcc913cada9b8953aeef1d507bffd8531ce59b14cc5aaf6a0d6891cefd1436237b7f22abaa90ae43381676")
    static let expectedM2 = hexData(
        "9b3ff380ed8dc75bd4ac36930c6cb84c8c3a22c776cd0027afa3d4e9d15f0df9d932a3c4f05f1595eb0fba22ba386f1447f671e10840c489c705cd850c985197")

    @Test func primeAndGeneratorMatchRFC5054() {
        #expect(SRP.generator == 5)
        // 3072-bit prime => 384 bytes, leading byte 0xFF.
        #expect(SRP.bytes(SRP.prime).count == 384)
        #expect(SRP.bytes(SRP.prime).first == 0xFF)
    }

    @Test func clientPublicKeyMatchesVector() {
        let context = SRPContext(username: Self.username, password: Self.password)
        let client = SRPClientSession(context: context, privateKey: Self.clientPrivate)
        #expect(client.publicKey == Self.expectedA)
    }

    @Test func serverPublicKeyMatchesVector() {
        let context = SRPContext(username: Self.username, password: Self.password)
        let server = SRPServerSession(
            context: context, privateKey: Self.serverPrivate, salt: Self.salt)
        #expect(server.publicKey == Self.expectedB)
    }

    @Test func clientProcessProducesVectorKeyAndProof() throws {
        let context = SRPContext(username: Self.username, password: Self.password)
        let client = SRPClientSession(context: context, privateKey: Self.clientPrivate)
        try client.process(serverPublicKey: Self.expectedB, salt: Self.salt)
        #expect(try client.sessionKey == Self.expectedK)
        #expect(try client.clientProof == Self.expectedM1)
    }

    @Test func clientVerifiesServerProofVector() throws {
        let context = SRPContext(username: Self.username, password: Self.password)
        let client = SRPClientSession(context: context, privateKey: Self.clientPrivate)
        try client.process(serverPublicKey: Self.expectedB, salt: Self.salt)
        #expect(try client.verifyProof(Self.expectedM2))
    }

    @Test func fullClientServerRoundTrip() throws {
        let context = SRPContext(username: Self.username, password: Self.password)
        let client = SRPClientSession(context: context, privateKey: Self.clientPrivate)
        let server = SRPServerSession(
            context: context, privateKey: Self.serverPrivate, salt: Self.salt)

        try client.process(serverPublicKey: server.publicKey, salt: server.salt)
        let verified = try server.processAndVerify(
            clientPublicKey: client.publicKey, clientProof: try client.clientProof)
        #expect(verified)
        #expect(try client.verifyProof(server.serverProof))
        #expect(try client.sessionKey == server.sessionKey)
    }

    @Test func wrongPasswordFailsServerVerification() throws {
        let serverContext = SRPContext(username: Self.username, password: "1111")
        let clientContext = SRPContext(username: Self.username, password: "9999")
        let server = SRPServerSession(
            context: serverContext, privateKey: Self.serverPrivate, salt: Self.salt)
        let client = SRPClientSession(context: clientContext, privateKey: Self.clientPrivate)

        try client.process(serverPublicKey: server.publicKey, salt: server.salt)
        let verified = try server.processAndVerify(
            clientPublicKey: client.publicKey, clientProof: try client.clientProof)
        #expect(!verified)
    }

    @Test func sessionKeyIsSHA512Sized() throws {
        let context = SRPContext(username: Self.username, password: Self.password)
        let client = SRPClientSession(context: context, privateKey: Self.clientPrivate)
        try client.process(serverPublicKey: Self.expectedB, salt: Self.salt)
        #expect(try client.sessionKey.count == 64)
    }

    @Test func accessingKeyBeforeProcessThrows() {
        let context = SRPContext(username: Self.username, password: Self.password)
        let client = SRPClientSession(context: context, privateKey: Self.clientPrivate)
        #expect(throws: SRPError.notProcessed) { _ = try client.sessionKey }
        #expect(throws: SRPError.notProcessed) { _ = try client.clientProof }
    }
}
