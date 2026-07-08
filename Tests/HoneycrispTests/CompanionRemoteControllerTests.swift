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
    private let holdConnect: Bool
    private var heldConnects: [CheckedContinuation<Void, Never>] = []

    init(dispatchFailures: Int = 0, holdConnect: Bool = false) {
        (connectionStates, continuation) =
            AsyncStream.makeStream(of: CompanionClient.ConnectionState.self)
        self.dispatchFailures = dispatchFailures
        self.holdConnect = holdConnect
    }

    nonisolated func emit(_ state: CompanionClient.ConnectionState) {
        continuation.yield(state)
    }

    /// Resume any `connect()` calls parked by `holdConnect`.
    func releaseConnects() {
        heldConnects.forEach { $0.resume() }
        heldConnects.removeAll()
    }

    func connect() async throws {
        connectCount += 1
        if holdConnect {
            await withCheckedContinuation { heldConnects.append($0) }
        }
    }
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
    let resolveCount = Counter()

    func resolve(identifier: String, timeout: Duration) async throws -> ResolvedAddress {
        resolveCount.increment()
        if let error { throw error }
        return address
    }
}

/// Thread-safe counter for call counting from Sendable fakes.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}

/// A client whose `connect()` always fails (simulates a stale cached address).
private actor FailingConnectClient: CompanionControlling {
    nonisolated let connectionStates: AsyncStream<CompanionClient.ConnectionState>
    private nonisolated let continuation: AsyncStream<CompanionClient.ConnectionState>.Continuation

    init() {
        (connectionStates, continuation) =
            AsyncStream.makeStream(of: CompanionClient.ConnectionState.self)
    }

    func connect() async throws { throw TestError.commandFailed }
    func disconnect() async {}
    func up() async throws {}
    func down() async throws {}
    func left() async throws {}
    func right() async throws {}
    func select() async throws {}
    func menu() async throws {}
    func homeHold() async throws {}
    func playPause() async throws {}
    func volumeUp() async throws {}
    func volumeDown() async throws {}
    func powerToggle() async throws {}
}

/// In-memory `AddressCaching` so tests never touch real UserDefaults.
private final class MemoryAddressCache: AddressCaching, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: ResolvedAddress] = [:]

    init(_ initial: [String: ResolvedAddress] = [:]) { store = initial }

    func address(for deviceID: String) -> ResolvedAddress? {
        lock.withLock { store[deviceID] }
    }
    func setAddress(_ address: ResolvedAddress, for deviceID: String) {
        lock.withLock { store[deviceID] = address }
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

/// Poll an async (e.g. actor-isolated) condition.
private func waitUntilAsync(isolation: isolated (any Actor)? = #isolation, _ condition: () async -> Bool) async {
    for _ in 0..<200 {
        if await condition() { return }
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
            addressCache: MemoryAddressCache(),
            makeClient: { _, _, _ in fake })

        #expect(await fake.connectCount == 0)

        try await controller.send(.homeHold)
        #expect(await fake.connectCount == 1)
        #expect(await fake.calls == ["homeHold"])

        try await controller.send(.select)
        #expect(await fake.connectCount == 1) // no reconnect
        #expect(await fake.calls == ["homeHold", "select"])
    }

    @Test("Two concurrent sends while disconnected coalesce into one connect")
    func concurrentSendsCoalesceConnect() async throws {
        let fake = FakeCompanionClient(holdConnect: true)
        var makeCount = 0
        let controller = CompanionRemoteController(
            device: validDevice(), resolver: FakeResolver(),
            addressCache: MemoryAddressCache(),
            makeClient: { _, _, _ in
                makeCount += 1
                return fake
            })

        // Two "button presses" land while disconnected; the first parks inside
        // the fake's held connect, the second must join it rather than start a
        // second connect (which would orphan a fully-connected client).
        let sendA = Task { try await controller.send(.up) }
        let sendB = Task { try await controller.send(.down) }

        await waitUntilAsync { await fake.connectCount >= 1 }
        // Give the second send time to reach the connect path while the first
        // is still held mid-connect, then let the connect finish.
        for _ in 0..<20 { await Task.yield() }
        await fake.releaseConnects()

        try await sendA.value
        try await sendB.value

        #expect(makeCount == 1) // only one client ever built
        #expect(await fake.connectCount == 1) // and connected exactly once
        // Presses queued during the connect are superseded by the newest one:
        // exactly one command reaches the device, not a stale burst.
        #expect(await fake.calls.count == 1)
        #expect(controller.connectionState == .connected)
    }

    @Test("A cached address skips discovery entirely")
    func cachedAddressSkipsResolver() async throws {
        let fake = FakeCompanionClient()
        let resolver = FakeResolver()
        let cache = MemoryAddressCache(["id-1": ResolvedAddress(host: "10.0.0.9", port: 7000)])
        var dialedHost: String?
        let controller = CompanionRemoteController(
            device: validDevice(), resolver: resolver,
            addressCache: cache,
            makeClient: { host, _, _ in
                dialedHost = host
                return fake
            })

        try await controller.send(.select)

        #expect(resolver.resolveCount.value == 0) // no mDNS browse
        #expect(dialedHost == "10.0.0.9")
        #expect(controller.connectionState == .connected)
    }

    @Test("A stale cached address falls back to discovery and refreshes the cache")
    func staleCacheFallsBack() async throws {
        let good = FakeCompanionClient()
        let resolver = FakeResolver(address: ResolvedAddress(host: "10.0.0.42", port: 49_152))
        let cache = MemoryAddressCache(["id-1": ResolvedAddress(host: "10.9.9.9", port: 7000)])
        var dialed: [String] = []
        let controller = CompanionRemoteController(
            device: validDevice(), resolver: resolver,
            addressCache: cache,
            makeClient: { host, _, _ in
                dialed.append(host)
                if host == "10.9.9.9" {
                    return FailingConnectClient()
                }
                return good
            })

        try await controller.send(.select)

        #expect(dialed == ["10.9.9.9", "10.0.0.42"]) // stale first, then discovered
        #expect(resolver.resolveCount.value == 1)
        #expect(controller.connectionState == .connected)
        #expect(cache.address(for: "id-1")?.host == "10.0.0.42") // cache refreshed
        #expect(await good.calls == ["select"])
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
            addressCache: MemoryAddressCache(),
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
            addressCache: MemoryAddressCache(),
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
            addressCache: MemoryAddressCache(),
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
            addressCache: MemoryAddressCache(),
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
            addressCache: MemoryAddressCache(),
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
            addressCache: MemoryAddressCache(),
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
            addressCache: MemoryAddressCache(),
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
