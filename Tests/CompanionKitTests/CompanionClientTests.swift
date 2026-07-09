import CryptoKit
import Foundation
import Testing
@testable import CompanionKit

/// Thread-safe recorder for the OPACK requests the fake accessory receives, so
/// synchronous responder closures can capture wire traffic for assertions.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [[String: OPACKValue]] = []

    func record(_ request: [String: OPACKValue]) {
        lock.lock(); defer { lock.unlock() }
        _requests.append(request)
    }

    var requests: [[String: OPACKValue]] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    /// HID commands seen so far as `(down, code)` pairs.
    var hidCommands: [(down: Bool, code: Int)] {
        requests.compactMap { req in
            guard req["_i"]?.asString == "_hidC",
                  let content = req["_c"]?.asStringDictionary,
                  let bts = content["_hBtS"]?.asInt,
                  let code = content["_hidC"]?.asInt
            else { return nil }
            return (down: bts == 1, code: code)
        }
    }
}

/// A transport that opens fine but fails every send, recording `close()` calls
/// so tests can assert failure paths release the connection.
private actor FailingSendTransport: CompanionTransport {
    private(set) var closeCount = 0

    func start(host: String, port: UInt16) async throws {}
    func send(_ data: Data) async throws {
        throw CompanionConnectionError.transportFailed("send failed")
    }
    func receive() async throws -> Data {
        // Park until the read loop is cancelled by close().
        try await Task.sleep(for: .seconds(60))
        throw CompanionConnectionError.closed
    }
    func close() async { closeCount += 1 }
}

/// Tests for the high-level `CompanionClient`, `CompanionPairer`, HID/InputAction
/// tables, and `CompanionDiscovery` identifier extraction.
struct CompanionClientTests {
    // Deterministic seeds shared with the other end-to-end suites.
    static let clientSeed = Data(repeating: 0x42, count: 32)
    static let pairingId = Data("11111111-2222-3333-4444-555555555555".utf8)
    static let serverEdSeed = Data(repeating: 0x33, count: 32)
    static let serverSrpPrivate = Data(repeating: 0x11, count: 32)
    static let serverSalt = Data(repeating: 0x01, count: 16)
    static let serverVerifySeed = Data(repeating: 0x55, count: 32)

    private func makeServer(pin: Int = 1111) -> FakeCompanionServer {
        FakeCompanionServer(
            pin: pin,
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

    /// Build a connected-capable client wired to a fake accessory. `attention`
    /// is the `state` value the accessory reports for `FetchAttentionState`.
    private func makeClient(
        credentials: HAPCredentials,
        attention: Int = 3,
        holdDuration: Double = 1.0,
        recorder: Recorder
    ) -> (CompanionClient, CompanionServerDriver) {
        let c2s = ByteChannel()
        let s2c = ByteChannel()
        let transport = MemoryTransport(outbound: c2s, inbound: s2c)
        let responder: CompanionResponder = { req in
            recorder.record(req)
            guard let id = req["_i"]?.asString, let x = req["_x"]?.asInt else { return nil }
            func ok(_ content: OPACKValue) -> [(String, OPACKValue)] {
                [("_i", .string(id)), ("_t", .int(3)), ("_x", .int(UInt64(x))), ("_c", content)]
            }
            switch id {
            case "_systemInfo", "_hidC", "_sessionStop":
                return ok(.dictionary([]))
            case "_sessionStart":
                return ok(.dictionary([(.string("_sid"), .int(0x1122_3344))]))
            case "FetchAttentionState":
                return ok(.dictionary([(.string("state"), .int(UInt64(attention)))]))
            default:
                return nil  // events (_interest) are fire-and-forget
            }
        }
        let driver = CompanionServerDriver(
            server: makeServer(), clientToServer: c2s, serverToClient: s2c, responder: responder)
        let client = CompanionClient(
            host: "test", port: 0, credentials: credentials,
            transport: transport, holdDuration: holdDuration)
        return (client, driver)
    }

    // MARK: - HID / InputAction tables

    @Test func hidCommandRawValuesMatchPyatv() {
        // Spot-check against pyatv's HidCommand enum (companion/api.py).
        #expect(HIDCommand.up.rawValue == 1)
        #expect(HIDCommand.down.rawValue == 2)
        #expect(HIDCommand.left.rawValue == 3)
        #expect(HIDCommand.right.rawValue == 4)
        #expect(HIDCommand.menu.rawValue == 5)
        #expect(HIDCommand.select.rawValue == 6)
        #expect(HIDCommand.home.rawValue == 7)
        #expect(HIDCommand.volumeUp.rawValue == 8)
        #expect(HIDCommand.volumeDown.rawValue == 9)
        #expect(HIDCommand.siri.rawValue == 10)
        #expect(HIDCommand.screensaver.rawValue == 11)
        #expect(HIDCommand.sleep.rawValue == 12)
        #expect(HIDCommand.wake.rawValue == 13)
        #expect(HIDCommand.playPause.rawValue == 14)
        #expect(HIDCommand.channelIncrement.rawValue == 15)
        #expect(HIDCommand.channelDecrement.rawValue == 16)
        #expect(HIDCommand.guide.rawValue == 17)
        #expect(HIDCommand.pageUp.rawValue == 18)
        #expect(HIDCommand.pageDown.rawValue == 19)
    }

    @Test func inputActionRawValuesMatchPyatv() {
        #expect(InputAction.singleTap.rawValue == 0)
        #expect(InputAction.doubleTap.rawValue == 1)
        #expect(InputAction.hold.rawValue == 2)
    }

    // MARK: - pressButton

    @Test func singleTapSendsDownThenUp() async throws {
        let credentials = try mintCredentials()
        let recorder = Recorder()
        let (client, driver) = makeClient(credentials: credentials, recorder: recorder)
        await driver.startLoop()
        try await client.connect()

        try await client.select()

        #expect(recorder.hidCommands.count == 2)
        #expect(recorder.hidCommands[0].down == true)
        #expect(recorder.hidCommands[0].code == HIDCommand.select.rawValue)
        #expect(recorder.hidCommands[1].down == false)
        #expect(recorder.hidCommands[1].code == HIDCommand.select.rawValue)

        await client.disconnect()
        await driver.stop()
    }

    @Test func doubleTapSendsFourEvents() async throws {
        let credentials = try mintCredentials()
        let recorder = Recorder()
        let (client, driver) = makeClient(credentials: credentials, recorder: recorder)
        await driver.startLoop()
        try await client.connect()

        try await client.pressButton(.home, action: .doubleTap)

        let hids = recorder.hidCommands
        #expect(hids.count == 4)
        #expect(hids.map(\.down) == [true, false, true, false])
        #expect(hids.allSatisfy { $0.code == HIDCommand.home.rawValue })

        await client.disconnect()
        await driver.stop()
    }

    @Test func holdWaitsBetweenDownAndUp() async throws {
        let credentials = try mintCredentials()
        let recorder = Recorder()
        let holdDuration = 0.25
        let (client, driver) = makeClient(
            credentials: credentials, holdDuration: holdDuration, recorder: recorder)
        await driver.startLoop()
        try await client.connect()

        let start = Date()
        try await client.homeHold()
        let elapsed = Date().timeIntervalSince(start)

        let hids = recorder.hidCommands
        #expect(hids.count == 2)
        #expect(hids.map(\.down) == [true, false])
        #expect(hids.allSatisfy { $0.code == HIDCommand.home.rawValue })
        // The up event must not fire until the hold duration has elapsed.
        #expect(elapsed >= holdDuration)

        await client.disconnect()
        await driver.stop()
    }

    // MARK: - Power

    @Test func powerToggleTurnsOffWhenOn() async throws {
        let credentials = try mintCredentials()
        let recorder = Recorder()
        // attention state 3 == Awake -> PowerState.on
        let (client, driver) = makeClient(credentials: credentials, attention: 3, recorder: recorder)
        await driver.startLoop()
        try await client.connect()

        // Connect's power fetch is fire-and-forget; refresh explicitly for a
        // deterministic starting state.
        #expect(try await client.refreshPowerState() == .on)
        try await client.powerToggle()

        // Toggling from On sends a single Sleep (up) HID event.
        #expect(recorder.hidCommands.count == 1)
        #expect(recorder.hidCommands[0].down == false)
        #expect(recorder.hidCommands[0].code == HIDCommand.sleep.rawValue)

        await client.disconnect()
        await driver.stop()
    }

    @Test func powerToggleTurnsOnWhenOff() async throws {
        let credentials = try mintCredentials()
        let recorder = Recorder()
        // attention state 1 == Asleep -> PowerState.off
        let (client, driver) = makeClient(credentials: credentials, attention: 1, recorder: recorder)
        await driver.startLoop()
        try await client.connect()

        #expect(try await client.refreshPowerState() == .off)
        try await client.powerToggle()

        // Toggling from Off sends a single Wake (up) HID event.
        #expect(recorder.hidCommands.count == 1)
        #expect(recorder.hidCommands[0].down == false)
        #expect(recorder.hidCommands[0].code == HIDCommand.wake.rawValue)

        await client.disconnect()
        await driver.stop()
    }

    @Test func systemStatusMappingMatchesPyatv() {
        #expect(CompanionClient.powerState(fromSystemStatus: 1) == .off)   // Asleep
        #expect(CompanionClient.powerState(fromSystemStatus: 2) == .on)    // Screensaver
        #expect(CompanionClient.powerState(fromSystemStatus: 3) == .on)    // Awake
        #expect(CompanionClient.powerState(fromSystemStatus: 4) == .on)    // Idle
        #expect(CompanionClient.powerState(fromSystemStatus: 0) == .unknown)
    }

    // MARK: - Error paths

    @Test func commandBeforeConnectThrowsNotConnected() async throws {
        let credentials = try mintCredentials()
        let recorder = Recorder()
        let (client, _) = makeClient(credentials: credentials, recorder: recorder)

        await #expect(throws: CompanionClient.ClientError.notConnected) {
            try await client.select()
        }
    }

    // MARK: - Pairing

    @Test func pairingProducesCredentials() async throws {
        let c2s = ByteChannel()
        let s2c = ByteChannel()
        let transport = MemoryTransport(outbound: c2s, inbound: s2c)
        let server = makeServer()
        let serverLtpk = server.ed25519PublicKey
        let driver = CompanionServerDriver(
            server: server, clientToServer: c2s, serverToClient: s2c, responder: { _ in nil })
        await driver.startLoop()

        let pairer = CompanionPairer(
            host: "test", port: 0, transport: transport,
            signingSeed: Self.clientSeed, pairingId: Self.pairingId)

        let showsPin = try await pairer.begin()
        #expect(showsPin == true)

        let credentials = try await pairer.finish(pin: 1111)
        #expect(credentials.ltpk == serverLtpk)
        #expect(credentials.ltsk == Self.clientSeed)
        #expect(credentials.atvId == FakeCompanionServer.serverId)
        #expect(credentials.clientId == Self.pairingId)

        await driver.stop()
    }

    @Test func pairingWithWrongPinThrowsDeviceError() async throws {
        let c2s = ByteChannel()
        let s2c = ByteChannel()
        let transport = MemoryTransport(outbound: c2s, inbound: s2c)
        let driver = CompanionServerDriver(
            server: makeServer(pin: 1111), clientToServer: c2s, serverToClient: s2c,
            responder: { _ in nil })
        await driver.startLoop()

        let pairer = CompanionPairer(
            host: "test", port: 0, transport: transport,
            signingSeed: Self.clientSeed, pairingId: Self.pairingId)

        _ = try await pairer.begin()
        await #expect(throws: PairingError.deviceError(0x02)) {
            _ = try await pairer.finish(pin: 9999)
        }

        await driver.stop()
    }

    @Test func beginFailureClosesConnection() async throws {
        let transport = FailingSendTransport()
        let pairer = CompanionPairer(
            host: "test", port: 0, transport: transport,
            signingSeed: Self.clientSeed, pairingId: Self.pairingId)

        await #expect(throws: CompanionConnectionError.transportFailed("send failed")) {
            try await pairer.begin()
        }
        // begin() must not leak the connection when the M1 exchange fails.
        #expect(await transport.closeCount == 1)
    }

    // MARK: - Discovery

    @Test func identifierExtractedFromRpmrtid() {
        #expect(CompanionDiscovery.identifier(fromTXT: ["rpmrtid": "AA:BB:CC"]) == "AA:BB:CC")
    }

    @Test func identifierExtractionIsCaseInsensitive() {
        // pyatv lowercases TXT keys; a mixed-case key must still resolve.
        #expect(CompanionDiscovery.identifier(fromTXT: ["RPMRtID": "X1"]) == "X1")
    }

    @Test func identifierNilWhenAbsent() {
        #expect(CompanionDiscovery.identifier(fromTXT: ["rpmd": "J305"]) == nil)
        #expect(CompanionDiscovery.identifier(fromTXT: [:]) == nil)
    }
}
