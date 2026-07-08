import CryptoKit
import Foundation
import Testing
@testable import CompanionKit

/// `CompanionConnection` actor tests over the in-memory transport: framing on
/// send, incremental reassembly on receive, and encryption applied to both
/// directions.
struct CompanionConnectionTests {
    private func makeConnection() -> (CompanionConnection, out: ByteChannel, `in`: ByteChannel) {
        let out = ByteChannel()
        let inbound = ByteChannel()
        let transport = MemoryTransport(outbound: out, inbound: inbound)
        return (CompanionConnection(transport: transport), out, inbound)
    }

    @Test func sendFramesPlaintext() async throws {
        let (conn, out, _) = makeConnection()
        try await conn.connect(host: "test", port: 0)
        try await conn.send(frame: CompanionFrame(type: .eOPACK, payload: Data("test".utf8)))
        let wire = try await out.receive()
        #expect(wire == hexData("08 00 00 04") + Data("test".utf8))
        await conn.close()
    }

    @Test func sendEmptyFrameHasZeroLength() async throws {
        let (conn, out, _) = makeConnection()
        try await conn.connect(host: "test", port: 0)
        try await conn.send(frame: CompanionFrame(type: .noOp, payload: Data()))
        let wire = try await out.receive()
        #expect(wire == hexData("01 00 00 00"))
        await conn.close()
    }

    @Test func receiveFrameFromStream() async throws {
        let (conn, _, inbound) = makeConnection()
        try await conn.connect(host: "test", port: 0)
        await inbound.send(hexData("07 00 00 02") + Data([0xAA, 0xBB]))
        var iterator = conn.frames.makeAsyncIterator()
        let frame = await iterator.next()
        #expect(frame?.type == .uOPACK)
        #expect(frame?.payload == Data([0xAA, 0xBB]))
        await conn.close()
    }

    @Test func receiveReassemblesPartialChunks() async throws {
        let (conn, _, inbound) = makeConnection()
        try await conn.connect(host: "test", port: 0)
        await inbound.send(hexData("08 00 00 04"))
        await inbound.send(Data("te".utf8))
        await inbound.send(Data("st".utf8))
        var iterator = conn.frames.makeAsyncIterator()
        let frame = await iterator.next()
        #expect(frame?.type == .eOPACK)
        #expect(frame?.payload == Data("test".utf8))
        await conn.close()
    }

    @Test func sendEncryptedMatchesReferenceVector() async throws {
        let (conn, out, _) = makeConnection()
        try await conn.connect(host: "test", port: 0)
        let key = Data(repeating: 0x6B, count: 32)
        await conn.enableEncryption(outputKey: key, inputKey: key)
        try await conn.send(frame: CompanionFrame(type: .eOPACK, payload: Data("test".utf8)))
        let wire = try await out.receive()
        // header length includes the +16 tag, then the reference ciphertext.
        #expect(wire == hexData("08 00 00 14") + hexData("def1c683c7247d3ab95088b75f4a88d71f209c5e"))
        await conn.close()
    }

    @Test func encryptedRoundTripBetweenTwoConnections() async throws {
        // Wire two connections back to back through paired channels.
        let a2b = ByteChannel()
        let b2a = ByteChannel()
        let connA = CompanionConnection(transport: MemoryTransport(outbound: a2b, inbound: b2a))
        let connB = CompanionConnection(transport: MemoryTransport(outbound: b2a, inbound: a2b))
        try await connA.connect(host: "a", port: 0)
        try await connB.connect(host: "b", port: 0)

        let keyC = Data(repeating: 0x01, count: 32) // A out / B in
        let keyS = Data(repeating: 0x02, count: 32) // B out / A in
        await connA.enableEncryption(outputKey: keyC, inputKey: keyS)
        await connB.enableEncryption(outputKey: keyS, inputKey: keyC)

        try await connA.send(frame: CompanionFrame(type: .eOPACK, payload: Data("ping".utf8)))
        var itB = connB.frames.makeAsyncIterator()
        let atB = await itB.next()
        #expect(atB?.payload == Data("ping".utf8))

        try await connB.send(frame: CompanionFrame(type: .eOPACK, payload: Data("pong".utf8)))
        var itA = connA.frames.makeAsyncIterator()
        let atA = await itA.next()
        #expect(atA?.payload == Data("pong".utf8))

        await connA.close()
        await connB.close()
    }
}
