import Foundation

/// High-level, user-facing entry point for driving an Apple TV over the
/// Companion protocol.
///
/// Wraps the lower CompanionKit layers (`CompanionConnection` ->
/// `CompanionProtocolLayer`) and exposes the surface a remote-control app needs:
/// connect/disconnect, HID button presses, text input, and power control. It is an `actor`
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
    /// Whether a `_tiStart` text-input session is open (so `_tiStop` has
    /// something to stop).
    private var textInputStarted = false
    private var textFocused = false

    private let stateStream: AsyncStream<ConnectionState>
    private let stateContinuation: AsyncStream<ConnectionState>.Continuation
    private let focusStream: AsyncStream<Bool>
    private let focusContinuation: AsyncStream<Bool>.Continuation

    /// Stream of connection-state transitions. Replays nothing on subscribe;
    /// read `state` for the current value.
    public nonisolated var connectionStates: AsyncStream<ConnectionState> { stateStream }

    /// Stream of text-field focus changes on the TV: `true` when a text field
    /// (e.g. a search box) gains focus, `false` when it loses it. Only
    /// changes are yielded.
    public nonisolated var textFocusStates: AsyncStream<Bool> { focusStream }

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
        (self.focusStream, self.focusContinuation) =
            AsyncStream.makeStream(of: Bool.self)
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
        // answer `FetchAttentionState`). Deliberately NOT awaited: blocking
        // here would add that request's full timeout to every connect (and to
        // every button press coalesced behind the connect) on such devices.
        Task { await self.initializePower(proto) }
        // Likewise best-effort: the text session makes the TV push focus
        // events, and its reply says whether a field is focused right now.
        Task { await self.initializeTextInput(proto) }
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
            // Short timeout: disconnect often runs precisely because the
            // session is dead (half-open TCP after the TV sleeps), and
            // waiting the default 5s here would stall every reconnect.
            _ = try? await proto.sendAndWait(
                identifier: "_sessionStop",
                content: .dictionary([
                    (.string("_srvT"), .string("com.apple.tvremoteservices")),
                    (.string("_sid"), .int(sid)),
                ]),
                timeout: 1.0)
        }

        await conn.close()
        connection = nil
        self.proto = nil
        _powerState = .unknown
        textInputStarted = false
        textFocused = false
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

    // MARK: - Text input

    /// Replace the text in the TV's focused text field (pyatv
    /// `CompanionKeyboard.text_set`). Returns the field's new text, or `nil`
    /// when no text field is focused on the TV.
    @discardableResult
    public func textSet(_ text: String) async throws -> String? {
        try await textInputCommand(text, clearPreviousInput: true)
    }

    /// Open the text-input session so the TV pushes `_tiStarted` /
    /// `_tiStopped` focus events (pyatv `CompanionKeyboard`, which starts the
    /// session at connect for the same reason).
    private func initializeTextInput(_ proto: CompanionProtocolLayer) async {
        for event in ["_tiStarted", "_tiStopped"] {
            await proto.onEvent(event) { [weak self] content in
                let focused = content["_tiD"] != nil
                Task { await self?.setTextFocused(focused) }
            }
        }
        guard !textInputStarted,
              let response = try? await proto.sendAndWait(identifier: "_tiStart")
        else { return }
        textInputStarted = true
        setTextFocused(response["_c"]?.asStringDictionary?["_tiD"] != nil)
    }

    /// pyatv's rule for all three messages: focused iff `_tiD` is present.
    private func setTextFocused(_ focused: Bool) {
        guard textFocused != focused else { return }
        textFocused = focused
        focusContinuation.yield(focused)
    }

    /// Port of pyatv `CompanionAPI.text_input_command`.
    private func textInputCommand(_ text: String, clearPreviousInput: Bool) async throws -> String? {
        let proto = try requireProto()

        // Restart the session so the `_tiStart` reply carries up-to-date
        // session data. pyatv opens the session at connect and so always
        // stops first; here it opens lazily, and only a started session is
        // stopped (the TV may not answer a stray `_tiStop`).
        if textInputStarted {
            _ = try await proto.sendAndWait(identifier: "_tiStop")
            textInputStarted = false
        }
        let response = try await proto.sendAndWait(identifier: "_tiStart")
        textInputStarted = true

        let tiData = response["_c"]?.asStringDictionary?["_tiD"]?.asData
        setTextFocused(tiData != nil)
        guard let tiData else { return nil }
        let properties = try RTIArchive.readProperties(tiData, [
            ["sessionUUID"],
            ["documentState", "docSt", "contextBeforeInput"],
        ])
        guard let sessionUUID = properties[0] as? Data else {
            throw CompanionProtocolError.missingField("sessionUUID")
        }
        var currentText = properties[1] as? String ?? ""

        if clearPreviousInput {
            let payload = try RTIArchive.clearTextPayload(sessionUUID: sessionUUID)
            try await proto.sendEvent(
                identifier: "_tiC",
                content: .dictionary([
                    (.string("_tiV"), .int(1)),
                    (.string("_tiD"), .data(payload)),
                ]))
            currentText = ""
        }

        if !text.isEmpty {
            let payload = try RTIArchive.inputTextPayload(sessionUUID: sessionUUID, text: text)
            try await proto.sendEvent(
                identifier: "_tiC",
                content: .dictionary([
                    (.string("_tiV"), .int(1)),
                    (.string("_tiD"), .data(payload)),
                ]))
            currentText += text
        }

        return currentText
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
    ///
    /// The connect-time power fetch is fire-and-forget (so it can't stall
    /// bring-up), so the cache may still be `.unknown` here; fetch on demand in
    /// that case rather than blindly waking an already-on TV.
    public func powerToggle() async throws {
        var state = _powerState
        if state == .unknown {
            state = (try? await refreshPowerState()) ?? .unknown
        }
        if state == .on {
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
