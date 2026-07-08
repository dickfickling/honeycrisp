import CompanionKit
import Foundation
import Testing
@testable import Honeycrisp

// MARK: - Test doubles

private enum TestError: Error { case commandFailed }

/// A fake `CompanionControlling` that records calls and can be told to fail a set
/// number of command dispatches. State transitions are driven manually via the
/// exposed continuation so mirroring can be exercised deterministically.
private actor FakeCompanionClient: CompanionControlling {
    nonisolated let connectionStates: AsyncStream<CompanionClient.ConnectionState>
    private nonisolated let continuation: AsyncStream<CompanionClient.ConnectionState>.Continuation

    private(set) var calls: [String] = []
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private var dispatchFailures: Int

    init(dispatchFailures: Int = 0) {
        (connectionStates, continuation) =
            AsyncStream.makeStream(of: CompanionClient.ConnectionState.self)
        self.dispatchFailures = dispatchFailures
    }

    nonisolated func emit(_ state: CompanionClient.ConnectionState) {
        continuation.yield(state)
    }

    func connect() async throws { connectCount += 1 }
    func disconnect() async { disconnectCount += 1 }

    private func record(_ name: String) throws {
        calls.append(name)
        if dispatchFailures > 0 {
            dispatchFailures -= 1
            throw TestError.commandFailed
        }
    }

    func up() async throws { try record("up") }
    func down() async throws { try record("down") }
    func left() async throws { try record("left") }
    func right() async throws { try record("right") }
    func select() async throws { try record("select") }
    func menu() async throws { try record("menu") }
    func homeHold() async throws { try record("homeHold") }
    func playPause() async throws { try record("playPause") }
    func volumeUp() async throws { try record("volumeUp") }
    func volumeDown() async throws { try record("volumeDown") }
    func powerToggle() async throws { try record("powerToggle") }
}

private struct FakeResolver: DeviceResolving {
    var address = ResolvedAddress(host: "10.0.0.5", port: 49_152)
    var error: Error?

    func resolve(identifier: String, timeout: Duration) async throws -> ResolvedAddress {
        if let error { throw error }
        return address
    }
}

private func validDevice() -> StoredDevice {
    StoredDevice(id: "id-1", name: "Living Room", credentials: "aa:bb:cc:dd")
}

/// Poll a main-actor condition, yielding so background tasks can run.
@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<200 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

// MARK: - Tests

@Suite("CompanionRemoteController")
@MainActor
struct CompanionRemoteControllerTests {
    @Test("First send lazily connects; subsequent sends reuse the session")
    func lazyConnect() async throws {
        let fake = FakeCompanionClient()
        let controller = CompanionRemoteController(
            device: validDevice(), resolver: FakeResolver(),
            makeClient: { _, _, _ in fake })

        #expect(await fake.connectCount == 0)

        try await controller.send(.homeHold)
        #expect(await fake.connectCount == 1)
        #expect(await fake.calls == ["homeHold"])

        try await controller.send(.select)
        #expect(await fake.connectCount == 1) // no reconnect
        #expect(await fake.calls == ["homeHold", "select"])
    }

    @Test("Every command maps to the matching client call")
    func commandMapping() async throws {
        let expected: [(RemoteCommand, String)] = [
            (.up, "up"), (.down, "down"), (.left, "left"), (.right, "right"),
            (.select, "select"), (.menu, "menu"), (.homeHold, "homeHold"),
            (.playPause, "playPause"), (.volumeUp, "volumeUp"),
            (.volumeDown, "volumeDown"), (.powerToggle, "powerToggle"),
        ]
        for (command, name) in expected {
            let fake = FakeCompanionClient()
            let controller = CompanionRemoteController(
                device: validDevice(), resolver: FakeResolver(),
                makeClient: { _, _, _ in fake })
            try await controller.send(command)
            #expect(await fake.calls == [name])
        }
    }

    @Test("A dropped command reconnects and retries once, succeeding")
    func retryOnceSucceeds() async throws {
        let first = FakeCompanionClient(dispatchFailures: 1)
        let second = FakeCompanionClient(dispatchFailures: 0)
        let clients = [first, second]
        var index = 0
        let controller = CompanionRemoteController(
            device: validDevice(), resolver: FakeResolver(),
            makeClient: { _, _, _ in defer { index += 1 }; return clients[index] })

        try await controller.send(.menu)

        #expect(await first.calls == ["menu"])
        #expect(await first.disconnectCount == 1) // torn down before retry
        #expect(await second.connectCount == 1)
        #expect(await second.calls == ["menu"])
        #expect(controller.connectionState == .connected)
    }

    @Test("A command that fails twice retries once then rethrows")
    func retryOnceThenThrows() async throws {
        let first = FakeCompanionClient(dispatchFailures: 5)
        let second = FakeCompanionClient(dispatchFailures: 5)
        let clients = [first, second]
        var index = 0
        let controller = CompanionRemoteController(
            device: validDevice(), resolver: FakeResolver(),
            makeClient: { _, _, _ in defer { index += 1 }; return clients[index] })

        await #expect(throws: TestError.self) {
            try await controller.send(.up)
        }

        #expect(await first.calls == ["up"])
        #expect(await second.calls == ["up"]) // retried exactly once
        #expect(index == 2) // only two clients ever built
        #expect(controller.lastError != nil)
    }

    @Test("A resolver failure on initial connect surfaces without retry")
    func resolverFailureSurfaces() async throws {
        let fake = FakeCompanionClient()
        let controller = CompanionRemoteController(
            device: validDevice(),
            resolver: FakeResolver(error: ControllerError.deviceNotFound("id-1")),
            makeClient: { _, _, _ in fake })

        await #expect(throws: ControllerError.self) {
            try await controller.send(.up)
        }
        #expect(await fake.connectCount == 0)
        #expect(controller.connectionState == .disconnected)
        #expect(controller.lastError != nil)
    }

    @Test("Invalid stored credentials fail with a typed error")
    func invalidCredentials() async throws {
        let controller = CompanionRemoteController(
            device: StoredDevice(id: "x", name: "n", credentials: "not-hex"),
            resolver: FakeResolver(),
            makeClient: { _, _, _ in FakeCompanionClient() })

        await #expect(throws: ControllerError.invalidCredentials) {
            try await controller.send(.up)
        }
    }

    @Test("Connection state mirrors the client's stream")
    func stateMirroring() async throws {
        let fake = FakeCompanionClient()
        let controller = CompanionRemoteController(
            device: validDevice(), resolver: FakeResolver(),
            makeClient: { _, _, _ in fake })

        try await controller.send(.up)
        #expect(controller.connectionState == .connected)

        // Simulate the session dropping underneath us.
        fake.emit(.disconnected)
        await waitUntil { controller.connectionState == .disconnected }
        #expect(controller.connectionState == .disconnected)
    }

    @Test("Teardown disconnects the client and resets state")
    func teardownDisconnects() async throws {
        let fake = FakeCompanionClient()
        let controller = CompanionRemoteController(
            device: validDevice(), resolver: FakeResolver(),
            makeClient: { _, _, _ in fake })

        try await controller.send(.up)
        await controller.teardown()

        #expect(await fake.disconnectCount == 1)
        #expect(controller.connectionState == .disconnected)
    }
}

// MARK: - Pairing model pure logic

@Suite("PairingModel list rules")
struct PairingModelTests {
    private func device(_ id: String?, _ name: String, host: String = "h") -> DiscoveredDevice {
        DiscoveredDevice(name: name, host: host, port: 1, identifier: id, txt: [:])
    }

    @Test("Re-yielded devices dedup by identifier, keeping the newest")
    func dedupKeepsNewest() {
        var acc: [String: DiscoveredDevice] = [:]
        acc = PairingModel.merged(acc, with: device("a", "Old", host: "1.1.1.1"))
        acc = PairingModel.merged(acc, with: device("a", "New", host: "2.2.2.2"))
        let rows = PairingModel.rows(from: acc, paired: [])
        #expect(rows.count == 1)
        #expect(rows[0].name == "New")
        #expect(rows[0].host == "2.2.2.2")
    }

    @Test("Devices without an identifier are excluded")
    func excludesIdentifierless() {
        var acc: [String: DiscoveredDevice] = [:]
        acc = PairingModel.merged(acc, with: device(nil, "Anon"))
        acc = PairingModel.merged(acc, with: device("b", "Named"))
        let rows = PairingModel.rows(from: acc, paired: [])
        #expect(rows.map(\.id) == ["b"])
    }

    @Test("Already-paired identifiers are marked and sorted by name")
    func marksPairedAndSorts() {
        var acc: [String: DiscoveredDevice] = [:]
        acc = PairingModel.merged(acc, with: device("z", "Zulu"))
        acc = PairingModel.merged(acc, with: device("a", "Alpha"))
        let rows = PairingModel.rows(from: acc, paired: ["a"])
        #expect(rows.map(\.name) == ["Alpha", "Zulu"])
        #expect(rows.first { $0.id == "a" }?.alreadyPaired == true)
        #expect(rows.first { $0.id == "z" }?.alreadyPaired == false)
    }
}
