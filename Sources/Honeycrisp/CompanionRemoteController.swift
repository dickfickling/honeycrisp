import CompanionKit
import Foundation
import Observation
import os

/// The narrow slice of `CompanionClient` the remote controller drives. Extracted
/// so the controller's connect / dispatch / retry logic is unit-testable with a
/// fake, without opening a real network connection.
///
/// `CompanionClient` is an `actor`; the production adapter (`LiveCompanionClient`)
/// forwards each requirement to it. All command methods are `async throws` so the
/// controller can `await` them across the actor boundary.
public protocol CompanionControlling: Sendable {
    /// Stream of the underlying client's connection-state transitions.
    nonisolated var connectionStates: AsyncStream<CompanionClient.ConnectionState> { get }
    func connect() async throws
    func disconnect() async
    func up() async throws
    func down() async throws
    func left() async throws
    func right() async throws
    func select() async throws
    func menu() async throws
    func homeHold() async throws
    func playPause() async throws
    func volumeUp() async throws
    func volumeDown() async throws
    func powerToggle() async throws
}

/// Production `CompanionControlling`, forwarding to a real `CompanionClient`.
public struct LiveCompanionClient: CompanionControlling {
    private let client: CompanionClient

    public init(client: CompanionClient) {
        self.client = client
    }

    public nonisolated var connectionStates: AsyncStream<CompanionClient.ConnectionState> {
        client.connectionStates
    }
    public func connect() async throws { try await client.connect() }
    public func disconnect() async { await client.disconnect() }
    public func up() async throws { try await client.up() }
    public func down() async throws { try await client.down() }
    public func left() async throws { try await client.left() }
    public func right() async throws { try await client.right() }
    public func select() async throws { try await client.select() }
    public func menu() async throws { try await client.menu() }
    public func homeHold() async throws { try await client.homeHold() }
    public func playPause() async throws { try await client.playPause() }
    public func volumeUp() async throws { try await client.volumeUp() }
    public func volumeDown() async throws { try await client.volumeDown() }
    public func powerToggle() async throws { try await client.powerToggle() }
}

/// A resolved network address for a device.
public struct ResolvedAddress: Equatable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

/// Resolves a paired device's *current* address from its stable identifier.
///
/// Apple TVs get new DHCP addresses over time, so the old app rescanned Bonjour
/// on every connect; this abstraction does the same and is faked in tests.
public protocol DeviceResolving: Sendable {
    func resolve(identifier: String, timeout: Duration) async throws -> ResolvedAddress
}

/// Production resolver: browses `_companion-link._tcp` TXT records for the
/// matching `rpmrtid` identifier and resolves only that endpoint, or times out.
public struct CompanionDeviceResolver: DeviceResolving {
    public init() {}

    public func resolve(identifier: String, timeout: Duration) async throws -> ResolvedAddress {
        let discovery = CompanionDiscovery()
        defer { discovery.stop() }

        return try await withThrowingTaskGroup(of: ResolvedAddress.self) { group in
            group.addTask {
                if let (host, port) = await discovery.resolveAddress(identifier: identifier) {
                    return ResolvedAddress(host: host, port: port)
                }
                throw ControllerError.deviceNotFound(identifier)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ControllerError.deviceNotFound(identifier)
            }
            defer { group.cancelAll() }
            // The first task to finish wins (a match, or whichever error fires first).
            return try await group.next()!
        }
    }
}

/// Remembers each device's last-known address so reconnects can skip the slow
/// (and occasionally flaky) mDNS browse and dial the device directly.
public protocol AddressCaching: AnyObject, Sendable {
    func address(for deviceID: String) -> ResolvedAddress?
    func setAddress(_ address: ResolvedAddress, for deviceID: String)
}

/// UserDefaults-backed `AddressCaching` ("host:port" under a per-device key).
/// `@unchecked Sendable`: stateless besides UserDefaults, which is thread-safe.
public final class DefaultsAddressCache: AddressCaching, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ deviceID: String) -> String { "lastAddress.\(deviceID)" }

    public func address(for deviceID: String) -> ResolvedAddress? {
        guard let stored = defaults.string(forKey: key(deviceID)) else { return nil }
        // Split on the LAST colon: IPv6 hosts contain colons themselves.
        guard let sep = stored.lastIndex(of: ":"),
              let port = UInt16(stored[stored.index(after: sep)...]) else { return nil }
        return ResolvedAddress(host: String(stored[..<sep]), port: port)
    }

    public func setAddress(_ address: ResolvedAddress, for deviceID: String) {
        defaults.set("\(address.host):\(address.port)", forKey: key(deviceID))
    }
}

/// Errors surfaced by the CompanionKit-backed controller.
public enum ControllerError: Error, Equatable, Sendable, LocalizedError {
    /// No live service advertised the device's identifier before the timeout.
    case deviceNotFound(String)
    /// The stored credentials string could not be parsed.
    case invalidCredentials

    public var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return "Device not found on the network"
        case .invalidCredentials:
            return "Stored credentials are invalid"
        }
    }
}

/// A `CompanionClient`-backed `RemoteControlling`.
///
/// Resolves the device's current address on connect (fresh discovery each time),
/// lazily connects on the first `send`, maps `RemoteCommand`s onto the client,
/// and — mirroring the old Electron app's `control()` — reconnects and retries a
/// command once if it fails on an established session before surfacing the error.
@Observable
@MainActor
public final class CompanionRemoteController: RemoteControlling {
    public private(set) var connectionState: ConnectionState = .disconnected
    public private(set) var lastError: String?

    @ObservationIgnored private let device: StoredDevice
    @ObservationIgnored private let resolver: any DeviceResolving
    @ObservationIgnored private let addressCache: any AddressCaching
    @ObservationIgnored private let makeClient: @MainActor (String, UInt16, HAPCredentials) -> any CompanionControlling
    @ObservationIgnored private let resolveTimeout: Duration
    @ObservationIgnored private let logger = Logger(subsystem: "us.fickling.honeycrisp2", category: "CompanionRemote")

    @ObservationIgnored private var client: (any CompanionControlling)?
    @ObservationIgnored private var mirrorTask: Task<Void, Never>?
    @ObservationIgnored private var parsedCredentials: HAPCredentials?
    /// The in-flight connect, shared by concurrent `send`s so two quick button
    /// presses while disconnected coalesce into a single resolve + connect
    /// (otherwise the loser's fully-connected client is orphaned forever).
    @ObservationIgnored private var connectTask: Task<Void, Error>?
    /// Monotonic ticket per `send`; commands that waited out a connect only
    /// fire if no newer command arrived meanwhile (see `send`).
    @ObservationIgnored private var sendTicket = 0
    /// Bumped by `teardown()`. A send that started before a teardown (device
    /// switch/removal) must not reconnect this discarded controller — that
    /// would resurrect a session to the old device that nothing ever closes.
    @ObservationIgnored private var generation = 0

    public init(
        device: StoredDevice,
        resolver: any DeviceResolving = CompanionDeviceResolver(),
        addressCache: any AddressCaching = DefaultsAddressCache(),
        resolveTimeout: Duration = .seconds(5),
        makeClient: @escaping @MainActor (String, UInt16, HAPCredentials) -> any CompanionControlling
            = { host, port, credentials in
                LiveCompanionClient(client: CompanionClient(host: host, port: port, credentials: credentials))
            }
    ) {
        self.device = device
        self.resolver = resolver
        self.addressCache = addressCache
        self.resolveTimeout = resolveTimeout
        self.makeClient = makeClient
    }

    // MARK: - RemoteControlling

    public func send(_ command: RemoteCommand) async throws {
        sendTicket += 1
        let ticket = sendTicket
        let gen = generation
        if client == nil {
            // Initial connect failures are surfaced directly (there is no
            // established session to reconnect).
            try await connect()
            // Presses that piled up while the connect was in flight would all
            // fire at once now (a burst of stale d-pad moves into the TV).
            // Only the newest one survives; the rest drop silently.
            guard ticket == sendTicket else {
                logger.info("Dropping superseded \(command.rawValue, privacy: .public) queued during connect")
                return
            }
        }
        do {
            try await dispatch(command)
        } catch {
            // The session dropped mid-command: reconnect (fresh discovery +
            // connect) and retry exactly once, then surface any failure.
            // Unless this controller was torn down (device switch/removal)
            // while the command was in flight — reconnecting then would
            // resurrect a session to the old device.
            guard gen == generation else { throw CompanionClient.ClientError.notConnected }
            logger.info("Command \(command.rawValue, privacy: .public) failed; reconnecting to retry once")
            await teardown()
            do {
                try await connect()
                guard ticket == sendTicket else { return }
                try await dispatch(command)
            } catch {
                lastError = Self.describe(error)
                throw error
            }
        }
    }

    public func teardown() async {
        generation += 1
        if let task = connectTask {
            connectTask = nil
            task.cancel()
            // Wait for the connect to settle so a client it produced is seen
            // below (and disconnected) rather than orphaned.
            _ = try? await task.value
        }
        mirrorTask?.cancel()
        mirrorTask = nil
        let old = client
        client = nil
        connectionState = .disconnected
        await old?.disconnect()
    }

    // MARK: - Internals

    /// Connect if needed, coalescing concurrent callers onto one in-flight
    /// attempt so exactly one client ever results. Public so the app can
    /// eagerly establish the session at launch / device switch.
    public func connect() async throws {
        if client != nil { return }
        if let connectTask {
            try await connectTask.value
            return
        }
        let task = Task { try await self.performConnect() }
        connectTask = task
        defer { if connectTask == task { connectTask = nil } }
        try await task.value
    }

    private func performConnect() async throws {
        let credentials = try credentials()
        connectionState = .connecting
        lastError = nil

        // Fast path: dial the last-known address directly (mDNS browsing takes
        // seconds and sometimes misses entirely). Fall back to a fresh
        // discovery resolve if the cached address no longer answers — devices
        // move to new DHCP addresses over time.
        if let cached = addressCache.address(for: device.id) {
            do {
                try await establishClient(at: cached, credentials: credentials)
                return
            } catch {
                logger.info("Cached address \(cached.host, privacy: .private):\(cached.port) failed (\(error.localizedDescription, privacy: .public)); falling back to discovery")
            }
        }

        let address: ResolvedAddress
        do {
            address = try await resolver.resolve(identifier: device.id, timeout: resolveTimeout)
        } catch {
            connectionState = .disconnected
            lastError = Self.describe(error)
            throw error
        }
        do {
            try await establishClient(at: address, credentials: credentials)
        } catch {
            connectionState = .disconnected
            lastError = Self.describe(error)
            throw error
        }
    }

    private func establishClient(at address: ResolvedAddress, credentials: HAPCredentials) async throws {
        let newClient = makeClient(address.host, address.port, credentials)
        startMirroring(newClient)
        do {
            try await newClient.connect()
        } catch {
            mirrorTask?.cancel()
            mirrorTask = nil
            throw error
        }
        client = newClient
        connectionState = .connected
        addressCache.setAddress(address, for: device.id)
    }

    private func dispatch(_ command: RemoteCommand) async throws {
        guard let client else { throw CompanionClient.ClientError.notConnected }
        switch command {
        case .up: try await client.up()
        case .down: try await client.down()
        case .left: try await client.left()
        case .right: try await client.right()
        case .select: try await client.select()
        case .menu: try await client.menu()
        case .homeHold: try await client.homeHold()
        case .playPause: try await client.playPause()
        case .volumeUp: try await client.volumeUp()
        case .volumeDown: try await client.volumeDown()
        case .powerToggle: try await client.powerToggle()
        }
    }

    /// Subscribe to a client's connection-state stream and mirror it into the
    /// observable `connectionState` (drives the UI, and catches later drops).
    private func startMirroring(_ client: any CompanionControlling) {
        mirrorTask?.cancel()
        let states = client.connectionStates
        mirrorTask = Task { [weak self] in
            for await state in states {
                self?.connectionState = Self.map(state)
            }
        }
    }

    private func credentials() throws -> HAPCredentials {
        if let parsedCredentials { return parsedCredentials }
        guard let credentials = try? HAPCredentials(string: device.credentials) else {
            throw ControllerError.invalidCredentials
        }
        parsedCredentials = credentials
        return credentials
    }

    private static func map(_ state: CompanionClient.ConnectionState) -> ConnectionState {
        switch state {
        case .disconnected: return .disconnected
        case .connecting: return .connecting
        case .connected: return .connected
        }
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
