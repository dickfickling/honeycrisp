import CryptoKit
import Foundation
import Testing
@testable import CompanionKit

/// `CompanionProtocolLayer` tests against the fake accessory over the
/// in-memory transport: xid correlation, event dispatch, `_em` error mapping,
/// and the full encrypted bring-up (Pair-Verify -> enable encryption ->
/// `_systemInfo` -> `_sessionStart`).
struct CompanionProtocolTests {
    // Deterministic seeds shared with PairingTests.
    static let clientSeed = Data(repeating: 0x42, count: 32)
    static let pairingId = Data("11111111-2222-3333-4444-555555555555".utf8)
    static let serverEdSeed = Data(repeating: 0x33, count: 32)
    static let serverSrpPrivate = Data(repeating: 0x11, count: 32)
    static let serverSalt = Data(repeating: 0x01, count: 16)
    static let serverVerifySeed = Data(repeating: 0x55, count: 32)
    static let clientVerifySeed = Data(repeating: 0x77, count: 32)

    private func makeServer() -> FakeCompanionServer {
        FakeCompanionServer(
            pin: 1111,
            edSeed: Self.serverEdSeed,
            srpPrivate: Self.serverSrpPrivate,
            srpSalt: Self.serverSalt,
            verifySeed: Self.serverVerifySeed
        )
    }

    private func mintCredentials() throws -> HAPCredentials {
        let server = makeServer()
        let setup = PairSetup(pin: 1111, signingSeed: Self.clientSeed, pairingId: Self.pairingId)
        let m2 = try server.handlePairSetup(setup.m1())
        let m3 = try setup.handleM2AndBuildM3(m2)
        let m4 = try server.handlePairSetup(m3)
        let m5 = try setup.handleM4AndBuildM5(m4)
        let m6 = try server.handlePairSetup(m5)
        return try setup.handleM6(m6)
    }

    /// Build a client connection + protocol wired to a server driver.
    private func makeStack(
        responder: @escaping CompanionResponder
    ) -> (CompanionProtocolLayer, CompanionConnection, CompanionServerDriver) {
        let c2s = ByteChannel()
        let s2c = ByteChannel()
        let conn = CompanionConnection(transport: MemoryTransport(outbound: c2s, inbound: s2c))
        let driver = CompanionServerDriver(
            server: makeServer(), clientToServer: c2s, serverToClient: s2c, responder: responder)
        let proto = CompanionProtocolLayer(connection: conn, initialXID: 1)
        return (proto, conn, driver)
    }

    // MARK: - Tests

    @Test func sendAndWaitCorrelatesByXID() async throws {
        // Responder echoes the request's xid back in the response content.
        let responder: CompanionResponder = { req in
            guard let id = req["_i"]?.asString, let x = req["_x"]?.asInt else { return nil }
            return [
                ("_i", .string(id)),
                ("_t", .int(3)),
                ("_x", .int(UInt64(x))),
                ("_c", .dictionary([(.string("echo"), .int(UInt64(x)))])),
            ]
        }
        let (proto, conn, driver) = makeStack(responder: responder)
        await driver.startLoop()
        try await conn.connect(host: "test", port: 0)

        async let r1 = proto.sendAndWait(identifier: "first")
        async let r2 = proto.sendAndWait(identifier: "second")
        let (resp1, resp2) = try await (r1, r2)

        // Each response carries the xid that its request was assigned, and the
        // echoed content matches — proving correlation, not just ordering.
        #expect(resp1["_x"]?.asInt == resp1["_c"]?.asStringDictionary?["echo"]?.asInt)
        #expect(resp2["_x"]?.asInt == resp2["_c"]?.asStringDictionary?["echo"]?.asInt)
        #expect(resp1["_x"]?.asInt != resp2["_x"]?.asInt)

        await driver.stop()
        await conn.close()
    }

    @Test func errorPayloadMapsToCommandFailed() async throws {
        let responder: CompanionResponder = { req in
            guard let x = req["_x"]?.asInt else { return nil }
            return [
                ("_t", .int(3)),
                ("_x", .int(UInt64(x))),
                ("_em", .string("boom")),
            ]
        }
        let (proto, conn, driver) = makeStack(responder: responder)
        await driver.startLoop()
        try await conn.connect(host: "test", port: 0)

        await #expect(throws: CompanionProtocolError.commandFailed("boom")) {
            _ = try await proto.sendAndWait(identifier: "_launchApp")
        }

        await driver.stop()
        await conn.close()
    }

    @Test func unsolicitedEventDispatchesToHandler() async throws {
        let responder: CompanionResponder = { _ in nil }
        let (proto, conn, driver) = makeStack(responder: responder)
        await driver.startLoop()
        try await conn.connect(host: "test", port: 0)

        let (stream, cont) = AsyncStream.makeStream(of: [String: OPACKValue].self)
        await proto.onEvent("_iMC") { content in cont.yield(content) }

        await driver.emit(.eOPACK, pairs: [
            ("_i", .string("_iMC")),
            ("_t", .int(1)),
            ("_c", .dictionary([(.string("volume"), .int(42))])),
        ])

        var iterator = stream.makeAsyncIterator()
        let content = await iterator.next()
        #expect(content?["volume"]?.asInt == 42)

        await driver.stop()
        await conn.close()
    }

    @Test func fullBringUpEstablishesEncryptedSession() async throws {
        let credentials = try mintCredentials()
        let remoteSID: UInt64 = 0x1122_3344

        // Capture the _systemInfo request the client sends so its wire shape
        // can be asserted below.
        let (systemInfoStream, systemInfoCont) =
            AsyncStream.makeStream(of: [String: OPACKValue].self)

        let responder: CompanionResponder = { req in
            guard let id = req["_i"]?.asString, let x = req["_x"]?.asInt else { return nil }
            switch id {
            case "_systemInfo":
                systemInfoCont.yield(req)
                return [
                    ("_i", .string(id)), ("_t", .int(3)), ("_x", .int(UInt64(x))),
                    ("_c", .dictionary([])),
                ]
            case "_sessionStart":
                return [
                    ("_i", .string(id)), ("_t", .int(3)), ("_x", .int(UInt64(x))),
                    ("_c", .dictionary([(.string("_sid"), .int(remoteSID))])),
                ]
            default:
                return nil
            }
        }

        let (proto, conn, driver) = makeStack(responder: responder)
        await driver.startLoop()
        try await conn.connect(host: "test", port: 0)

        try await proto.start(credentials: credentials, verifySeed: Self.clientVerifySeed)

        let sid = await proto.sessionID
        #expect(sid != nil)
        #expect((sid! >> 32) == remoteSID)

        // pyatv sends `_idsID` as creds.client_id, which is raw *bytes* — it
        // must arrive as OPACK data (not a string) carrying the credentials'
        // clientId. OPACKValue equality is case-sensitive, so this locks the
        // wire type marker down, not just the byte content.
        var infoIterator = systemInfoStream.makeAsyncIterator()
        let systemInfo = await infoIterator.next()
        let content = systemInfo?["_c"]?.asStringDictionary
        #expect(content?["_idsID"] == .data(Self.pairingId))
        #expect(content?["_idsID"]?.asData == Self.pairingId)
        #expect(content?["_idsID"]?.asString == nil)

        await driver.stop()
        await conn.close()
    }
}
