import Foundation

/// High-level, user-facing entry point for driving an Apple TV over the
/// Companion protocol.
///
/// Wraps the lower CompanionKit layers (`CompanionConnection` ->
/// `CompanionProtocolLayer`) and exposes the surface a remote-control app needs:
/// connect/disconnect, HID button presses, and power control. It is an `actor`
/// so a thin `@MainActor` adapter (the app's `RemoteControlling`) can call its
/// `async` methods directly.
///
/// Behavior follows pyatv's `CompanionAPI` / `CompanionRemoteControl` /
/// `CompanionPower` (`protocols/companion/api.py`, `__init__.py`).
public actor CompanionClient {
    /// Observable connection lifecycle state.
    public enum ConnectionState: Sendable, Equatable {
        case disconnected
        case connecting
        case connected
    }

    /// Device power state, mirroring pyatv's `PowerState` (`const.py`).
    public enum PowerState: Int, Sendable, Equatable {
        case unknown = 0
        case off = 1
        case on = 2
    }

    /// Errors surfaced by the high-level client.
    public enum ClientError: Error, Equatable, Sendable {
        /// A command was issued before a successful `connect()`.
        case notConnected
    }

    // MARK: - Configuration

    private let host: String
    private let port: UInt16
    private let credentials: HAPCredentials
    private let transport: CompanionTransport
    private let deviceInfo: CompanionDeviceInfo
    /// Duration a `.hold` press keeps the button down (pyatv `_press_button`
    /// default `delay=1`). Injectable so tests need not wait a real second.
    private let holdDuration: Double

    // MARK: - Live state

    private var connection: CompanionConnection?
    private var proto: CompanionProtocolLayer?
    private var _state: ConnectionState = .disconnected
    private var _powerState: PowerState = .unknown
    private var subscribedEvents: [String] = []

    private let stateStream: AsyncStream<ConnectionState>
    private let stateContinuation: AsyncStream<ConnectionState>.Continuation

    /// Stream of connection-state transitions. Replays nothing on subscribe;
    /// read `state` for the current value.
    public nonisolated var connectionStates: AsyncStream<ConnectionState> { stateStream }

    public init(
        host: String,
        port: UInt16,
        credentials: HAPCredentials,
        transport: CompanionTransport = NWCompanionTransport(),
        deviceInfo: CompanionDeviceInfo = CompanionDeviceInfo(),
        holdDuration: Double = 1.0
    ) {
        self.host = host
        self.port = port
        self.credentials = credentials
        self.transport = transport
        self.deviceInfo = deviceInfo
        self.holdDuration = holdDuration
        (self.stateStream, self.stateContinuation) =
            AsyncStream.makeStream(of: ConnectionState.self)
    }

    // MARK: - Lifecycle

    /// The current connection state.
    public var state: ConnectionState { _state }

    /// Open the connection and run the full Companion bring-up (Pair-Verify,
    /// encryption, `_systemInfo`, `_sessionStart`), then initialize power state.
    public func connect() async throws {
        guard _state == .disconnected else { return }
        setState(.connecting)

        let conn = CompanionConnection(transport: transport)
        let proto = CompanionProtocolLayer(connection: conn)
        do {
            try await conn.connect(host: host, port: port)
            try await proto.start(credentials: credentials, deviceInfo: deviceInfo)
        } catch {
            await conn.close()
            setState(.disconnected)
            throw error
        }

        self.connection = conn
        self.proto = proto
        setState(.connected)

        // Best-effort power initialization, mirroring pyatv's
        // `CompanionPower.initialize` (swallows failures — some devices do not
        // answer `FetchAttentionState`).
        await initializePower(proto)
    }

    /// Tear down the session and close the connection.
    ///
    /// Mirrors pyatv `CompanionAPI.disconnect`: unsubscribe events, send
    /// `_sessionStop`, then stop the protocol. Teardown errors are swallowed,
    /// exactly as pyatv does.
    public func disconnect() async {
        guard let conn = connection, let proto else {
            setState(.disconnected)
            return
        }

        for event in subscribedEvents {
            try? await proto.sendEvent(
                identifier: "_interest",
                content: .dictionary([(.string("_deregEvents"), .array([.string(event)]))]))
        }
        subscribedEvents.removeAll()

        if let sid = await proto.sessionID {
            _ = try? await proto.sendAndWait(
                identifier: "_sessionStop",
                content: .dictionary([
                    (.string("_srvT"), .string("com.apple.tvremoteservices")),
                    (.string("_sid"), .int(sid)),
                ]))
        }

        await conn.close()
        connection = nil
        self.proto = nil
        _powerState = .unknown
        setState(.disconnected)
    }

    private func setState(_ newState: ConnectionState) {
        guard _state != newState else { return }
        _state = newState
        stateContinuation.yield(newState)
    }

    private func requireProto() throws -> CompanionProtocolLayer {
        guard let proto, _state == .connected else { throw ClientError.notConnected }
        return proto
    }

    // MARK: - HID

    /// Send a single HID button event.
    ///
    /// pyatv `CompanionAPI.hid_command`: `_hidC` request carrying
    /// `{"_hBtS": 1 (down) | 2 (up), "_hidC": command.value}`.
    public func hidCommand(down: Bool, command: HIDCommand) async throws {
        let proto = try requireProto()
        _ = try await proto.sendAndWait(
            identifier: "_hidC",
            content: .dictionary([
                (.string("_hBtS"), .int(down ? 1 : 2)),
                (.string("_hidC"), .int(UInt64(command.rawValue))),
            ]))
    }

    /// Press a button, expanding the action into HID down/up events.
    ///
    /// Port of pyatv `CompanionRemoteControl._press_button`:
    /// single tap = down + up; hold = down, wait `holdDuration`, up;
    /// double tap = down, up, down, up.
    public func pressButton(_ command: HIDCommand, action: InputAction = .singleTap) async throws {
        switch action {
        case .singleTap:
            try await hidCommand(down: true, command: command)
            try await hidCommand(down: false, command: command)
        case .hold:
            try await hidCommand(down: true, command: command)
            try await Task.sleep(nanoseconds: UInt64(holdDuration * 1_000_000_000))
            try await hidCommand(down: false, command: command)
        case .doubleTap:
            try await hidCommand(down: true, command: command)
            try await hidCommand(down: false, command: command)
            try await hidCommand(down: true, command: command)
            try await hidCommand(down: false, command: command)
        }
    }

    // MARK: - Button conveniences

    public func up(_ action: InputAction = .singleTap) async throws {
        try await pressButton(.up, action: action)
    }
    public func down(_ action: InputAction = .singleTap) async throws {
        try await pressButton(.down, action: action)
    }
    public func left(_ action: InputAction = .singleTap) async throws {
        try await pressButton(.left, action: action)
    }
    public func right(_ action: InputAction = .singleTap) async throws {
        try await pressButton(.right, action: action)
    }
    public func select(_ action: InputAction = .singleTap) async throws {
        try await pressButton(.select, action: action)
    }
    public func menu(_ action: InputAction = .singleTap) async throws {
        try await pressButton(.menu, action: action)
    }
    public func home(_ action: InputAction = .singleTap) async throws {
        try await pressButton(.home, action: action)
    }
    /// Long-press Home (pyatv `home_hold`): Home button held for `holdDuration`.
    public func homeHold() async throws {
        try await pressButton(.home, action: .hold)
    }
    public func playPause() async throws {
        try await pressButton(.playPause)
    }
    public func volumeUp() async throws {
        try await pressButton(.volumeUp)
    }
    public func volumeDown() async throws {
        try await pressButton(.volumeDown)
    }

    // MARK: - Power

    /// The last known device power state.
    public var powerState: PowerState { _powerState }

    /// Turn the device on. pyatv `CompanionPower.turn_on` sends a single HID
    /// *up* (`down=false`) Wake event.
    public func turnOn() async throws {
        try await hidCommand(down: false, command: .wake)
    }

    /// Turn the device off. pyatv `CompanionPower.turn_off` sends a single HID
    /// *up* (`down=false`) Sleep event.
    public func turnOff() async throws {
        try await hidCommand(down: false, command: .sleep)
    }

    /// Toggle power based on the current state, mirroring the old Honeycrisp
    /// server's `power_toggle`: turn off only when known-on, otherwise turn on.
    public func powerToggle() async throws {
        if _powerState == .on {
            try await turnOff()
        } else {
            try await turnOn()
        }
    }

    /// Query the device's current power state via `FetchAttentionState` and
    /// update the cached value. Returns the refreshed state.
    @discardableResult
    public func refreshPowerState() async throws -> PowerState {
        let proto = try requireProto()
        let resp = try await proto.sendAndWait(identifier: "FetchAttentionState")
        guard let stateValue = resp["_c"]?.asStringDictionary?["state"]?.asInt else {
            throw CompanionProtocolError.missingField("state")
        }
        _powerState = Self.powerState(fromSystemStatus: stateValue)
        return _powerState
    }

    private func initializePower(_ proto: CompanionProtocolLayer) async {
        do {
            _ = try await refreshPowerState()
        } catch {
            // pyatv logs and continues; power_state simply stays .unknown.
            return
        }
        // Subscribe to live updates (pyatv subscribes both event names).
        for event in ["SystemStatus", "TVSystemStatus"] {
            await proto.onEvent(event) { [weak self] content in
                guard let value = content["state"]?.asInt else { return }
                Task { await self?.applyPowerUpdate(value) }
            }
            do {
                try await proto.sendEvent(
                    identifier: "_interest",
                    content: .dictionary([(.string("_regEvents"), .array([.string(event)]))]))
                subscribedEvents.append(event)
            } catch {
                // Ignore subscription failures; the initial fetch already set state.
            }
        }
    }

    private func applyPowerUpdate(_ systemStatus: Int) {
        _powerState = Self.powerState(fromSystemStatus: systemStatus)
    }

    /// Map a raw Companion `SystemStatus` value to a `PowerState`.
    ///
    /// pyatv `_system_status_to_power_state`: `Asleep` (1) -> off;
    /// `Screensaver` (2), `Awake` (3), `Idle` (4) -> on; anything else ->
    /// unknown.
    static func powerState(fromSystemStatus status: Int) -> PowerState {
        switch status {
        case 1: return .off
        case 2, 3, 4: return .on
        default: return .unknown
        }
    }
}
