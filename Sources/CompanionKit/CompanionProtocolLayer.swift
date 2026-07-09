import CryptoKit
import Foundation

/// OPACK message type discriminator (`_t` field). Port of pyatv
/// `protocol.py` `MessageType`.
public enum MessageType: Int, Sendable {
    case event = 1
    case request = 2
    case response = 3
}

/// Errors surfaced by the Companion message layer.
public enum CompanionProtocolError: Error, Equatable, Sendable {
    /// The device replied with an `_em` error payload (pyatv
    /// `"Command failed: ..."`).
    case commandFailed(String)
    /// A required field was missing from a device response.
    case missingField(String)
    /// No response arrived within the timeout window.
    case timeout
    /// The response was not an OPACK dictionary.
    case unexpectedResponse
}

/// Local device identity sent to the accessory in `_systemInfo`. Mirrors the
/// values pyatv derives from its settings; parameterized minimally with the
/// client name defaulting to "Honeycrisp".
public struct CompanionDeviceInfo: Sendable {
    public var name: String
    public var model: String
    /// pyatv `info.rp_id` — the local device's remote-pairing identifier
    /// (`_i` in the `_systemInfo` payload).
    public var rpID: String
    /// pyatv `info.device_id` — sent as `_pubID`.
    public var deviceID: String
    /// pyatv hardcoded software version string (`_sv`).
    public var softwareVersion: String

    public init(
        name: String = "Honeycrisp",
        model: String = "iPhone14,3",
        rpID: String = "Honeycrisp",
        deviceID: String = "Honeycrisp",
        softwareVersion: String = "170.18"
    ) {
        self.name = name
        self.model = model
        self.rpID = rpID
        self.deviceID = deviceID
        self.softwareVersion = softwareVersion
    }
}

/// OPACK message layer atop `CompanionConnection`.
///
/// Port of pyatv's `CompanionProtocol` (`protocol.py`) plus the message
/// shapes from `api.py`:
///
/// - Builds `{"_i", "_t", "_c", "_x"}` OPACK messages, auto-incrementing the
///   `_x` transaction id.
/// - `sendAndWait` correlates a response to its request by `_x`; auth frames
///   correlate by frame type instead (pyatv's `FrameIdType` union).
/// - Unsolicited events (`_t == 1`) are dispatched to handlers registered by
///   `_i` name.
/// - `_em` error payloads are surfaced as `CompanionProtocolError.commandFailed`.
/// - `start(...)` performs the bring-up: Pair-Verify over the auth frames,
///   enable encryption with the derived directional keys, then the encrypted
///   `_systemInfo` and `_sessionStart` exchange.
public actor CompanionProtocolLayer {
    // pyatv `SRP_SALT` / `SRP_OUTPUT_INFO` / `SRP_INPUT_INFO`.
    static let encryptSalt = ""
    static let outputInfo = "ClientEncrypt-main"
    static let inputInfo = "ServerEncrypt-main"

    private static let authFrameTypes: Set<FrameType> = [.psStart, .psNext, .pvStart, .pvNext]
    private static let opackFrameTypes: Set<FrameType> = [.uOPACK, .eOPACK, .pOPACK]

    private enum PendingKey: Hashable {
        case xid(Int)
        case frame(UInt8)
    }

    private let connection: CompanionConnection
    private var xid: Int
    private var pending: [PendingKey: CheckedContinuation<[String: OPACKValue], Error>] = [:]
    private var timeoutTasks: [PendingKey: Task<Void, Never>] = [:]
    private var eventHandlers: [String: @Sendable ([String: OPACKValue]) -> Void] = [:]
    private var receiveTask: Task<Void, Never>?

    /// Combined session identifier established by `_sessionStart`
    /// (`(remote_sid << 32) | local_sid`), or `nil` until then.
    public private(set) var sessionID: UInt64?

    public init(connection: CompanionConnection, initialXID: Int? = nil) {
        self.connection = connection
        // pyatv seeds `_xid` with `randint(0, 2**16)`.
        self.xid = initialXID ?? Int.random(in: 0 ... 0x1_0000)
    }

    // MARK: - Event registration

    /// Register a handler for unsolicited events with the given `_i` name.
    /// The handler receives the event's `_c` content dictionary.
    public func onEvent(_ name: String, _ handler: @Sendable @escaping ([String: OPACKValue]) -> Void) {
        eventHandlers[name] = handler
        // Registering a handler implies the caller wants to receive frames.
        startReceiving()
    }

    // MARK: - Bring-up

    /// Full connection bring-up.
    ///
    /// Order follows pyatv's actual sequence (`protocol.start` +
    /// `api.connect`): Pair-Verify, then enable encryption with the derived
    /// keys, then the *encrypted* `_systemInfo`, then `_sessionStart`.
    public func start(
        credentials: HAPCredentials,
        deviceInfo: CompanionDeviceInfo = CompanionDeviceInfo(),
        verifySeed: Data? = nil
    ) async throws {
        startReceiving()

        // 1. Pair-Verify over the PV auth frames (plaintext).
        let verify = PairVerify(credentials: credentials, verifyPrivateSeed: verifySeed)
        let resp1 = try await exchangeAuth(
            .pvStart,
            [("_pd", .data(verify.m1())), ("_auTy", .int(4))],
            responseType: .pvNext
        )
        guard let pd2 = resp1["_pd"]?.asData else {
            throw CompanionProtocolError.missingField("_pd")
        }
        let m3 = try verify.handleM2AndBuildM3(pd2)
        _ = try await exchangeAuth(.pvNext, [("_pd", .data(m3))], responseType: .pvNext)

        // 2. Derive directional keys and enable encryption.
        let outKey = try verify.deriveKey(salt: Self.encryptSalt, info: Self.outputInfo)
        let inKey = try verify.deriveKey(salt: Self.encryptSalt, info: Self.inputInfo)
        await connection.enableEncryption(
            outputKey: outKey.rawData, inputKey: inKey.rawData)

        // 3. Encrypted _systemInfo.
        _ = try await sendAndWait(
            identifier: "_systemInfo",
            content: systemInfoContent(credentials: credentials, deviceInfo: deviceInfo)
        )

        // 4. _sessionStart.
        let localSID = UInt64(UInt32.random(in: 0 ... UInt32.max))
        let resp = try await sendAndWait(
            identifier: "_sessionStart",
            content: .dictionary([
                (.string("_srvT"), .string("com.apple.tvremoteservices")),
                (.string("_sid"), .int(localSID)),
            ])
        )
        if let content = resp["_c"]?.asStringDictionary, let remote = content["_sid"]?.asUInt64 {
            sessionID = (remote << 32) | localSID
        }
    }

    private func systemInfoContent(
        credentials: HAPCredentials, deviceInfo: CompanionDeviceInfo
    ) -> OPACKValue {
        // Order matches pyatv api.py `system_info`. `_idsID` is
        // `creds.client_id` which is *bytes* in pyatv, so it must be packed
        // as OPACK raw data (not a string) for wire compatibility.
        return .dictionary([
            (.string("_bf"), .int(0)),
            (.string("_cf"), .int(512)),
            (.string("_clFl"), .int(128)),
            (.string("_i"), .string(deviceInfo.rpID)),
            (.string("_idsID"), .data(credentials.clientId)),
            (.string("_pubID"), .string(deviceInfo.deviceID)),
            (.string("_sf"), .int(256)),
            (.string("_sv"), .string(deviceInfo.softwareVersion)),
            (.string("model"), .string(deviceInfo.model)),
            (.string("name"), .string(deviceInfo.name)),
        ])
    }

    // MARK: - Request / response

    /// Send an OPACK command and await the correlated response.
    ///
    /// Builds `{"_i": identifier, "_t": messageType, "_c": content, "_x": xid}`
    /// (pyatv `_send_command` + `exchange_opack`).
    @discardableResult
    public func sendAndWait(
        identifier: String,
        content: OPACKValue = .dictionary([]),
        messageType: MessageType = .request,
        frameType: FrameType = .eOPACK,
        timeout: Double = 5.0
    ) async throws -> [String: OPACKValue] {
        let x = nextXID()
        let pairs: [(String, OPACKValue)] = [
            ("_i", .string(identifier)),
            ("_t", .int(UInt64(messageType.rawValue))),
            ("_c", content),
            ("_x", .int(UInt64(x))),
        ]
        let response = try await exchange(
            frameType: frameType, pairs: pairs, key: .xid(x), timeout: timeout)
        try checkError(response)
        return response
    }

    /// Send an OPACK event message (`_t == event`) without awaiting a response.
    ///
    /// Port of pyatv's `send_opack` used by `_send_event`: events (e.g.
    /// `_interest` subscribe/unsubscribe, `_hidT`) are fire-and-forget and the
    /// device never replies with a correlated `_x`.
    public func sendEvent(
        identifier: String,
        content: OPACKValue = .dictionary([]),
        frameType: FrameType = .eOPACK
    ) async throws {
        startReceiving()
        let pairs: [(String, OPACKValue)] = [
            ("_i", .string(identifier)),
            ("_t", .int(UInt64(MessageType.event.rawValue))),
            ("_c", content),
            ("_x", .int(UInt64(nextXID()))),
        ]
        try await sendFrame(frameType: frameType, pairs: pairs)
    }

    /// Exchange an auth (`PS_*`/`PV_*`) frame, correlating the response by
    /// frame type (pyatv `exchange_auth`).
    @discardableResult
    public func exchangeAuth(
        _ frameType: FrameType,
        _ pairs: [(String, OPACKValue)],
        responseType: FrameType,
        timeout: Double = 5.0
    ) async throws -> [String: OPACKValue] {
        // pyatv's `send_opack` also stamps an `_x` on auth frames even though
        // dispatch keys off the frame type.
        let x = nextXID()
        var stamped = pairs
        stamped.append(("_x", .int(UInt64(x))))
        let response = try await exchange(
            frameType: frameType, pairs: stamped,
            key: .frame(responseType.rawValue), timeout: timeout)
        try checkError(response)
        return response
    }

    private func exchange(
        frameType: FrameType,
        pairs: [(String, OPACKValue)],
        key: PendingKey,
        timeout: Double
    ) async throws -> [String: OPACKValue] {
        startReceiving()
        return try await withCheckedThrowingContinuation { cont in
            pending[key] = cont
            timeoutTasks[key] = Task { [weak self] in
                // Return (rather than firing) on cancellation: auth exchanges
                // reuse the same frame-type key, so a stale cancelled timer
                // must not complete a later exchange's continuation.
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                } catch {
                    return
                }
                await self?.complete(key, with: .failure(CompanionProtocolError.timeout))
            }
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.sendFrame(frameType: frameType, pairs: pairs)
                } catch {
                    await self.complete(key, with: .failure(error))
                }
            }
        }
    }

    private func sendFrame(frameType: FrameType, pairs: [(String, OPACKValue)]) async throws {
        let dict = OPACKValue.dictionary(pairs.map { (OPACKValue.string($0.0), $0.1) })
        let data = try OPACK.pack(dict)
        try await connection.send(frame: CompanionFrame(type: frameType, payload: data))
    }

    private func nextXID() -> Int {
        let x = xid
        xid += 1
        return x
    }

    private func checkError(_ dict: [String: OPACKValue]) throws {
        if let em = dict["_em"] {
            throw CompanionProtocolError.commandFailed(em.asString ?? String(describing: em))
        }
    }

    private func complete(_ key: PendingKey, with result: Result<[String: OPACKValue], Error>) {
        timeoutTasks.removeValue(forKey: key)?.cancel()
        guard let cont = pending.removeValue(forKey: key) else { return }
        cont.resume(with: result)
    }

    // MARK: - Receiving

    private func startReceiving() {
        guard receiveTask == nil else { return }
        let conn = connection
        receiveTask = Task { [weak self] in
            for await frame in conn.frames {
                await self?.handle(frame)
            }
            await self?.failAllPending()
        }
    }

    private func failAllPending() {
        let keys = Array(pending.keys)
        for key in keys {
            complete(key, with: .failure(CompanionConnectionError.closed))
        }
    }

    private func handle(_ frame: CompanionFrame) {
        let isAuth = Self.authFrameTypes.contains(frame.type)
        let isOPACK = Self.opackFrameTypes.contains(frame.type)
        guard isAuth || isOPACK else { return }

        guard let value = try? OPACK.unpack(frame.payload),
              let dict = value.asStringDictionary
        else { return }

        if isAuth {
            complete(.frame(frame.type.rawValue), with: .success(dict))
            return
        }

        switch dict["_t"]?.asInt {
        case MessageType.event.rawValue:
            if let name = dict["_i"]?.asString {
                let content = dict["_c"]?.asStringDictionary ?? [:]
                eventHandlers[name]?(content)
            }
        case MessageType.response.rawValue:
            if let x = dict["_x"]?.asInt {
                complete(.xid(x), with: .success(dict))
            }
        default:
            break
        }
    }
}

// MARK: - OPACKValue access helpers

extension OPACKValue {
    /// The value as an `Int`, if it is an integer that fits. `Int(exactly:)`
    /// rather than `Int(_:)`: an inbound 8-byte value above Int.max must be
    /// rejected, not trap — frames are attacker-influenced before encryption.
    var asInt: Int? {
        if case .int(let v, _) = self { return Int(exactly: v) }
        return nil
    }

    var asUInt64: UInt64? {
        if case .int(let v, _) = self { return v }
        return nil
    }

    var asString: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var asData: Data? {
        if case .data(let d) = self { return d }
        return nil
    }

    /// The value as a `[String: OPACKValue]`, when it is a dictionary whose
    /// keys are all strings (last-wins on duplicate keys, matching a decoded
    /// mapping).
    var asStringDictionary: [String: OPACKValue]? {
        guard case .dictionary(let pairs) = self else { return nil }
        var result: [String: OPACKValue] = [:]
        for (key, val) in pairs {
            guard case .string(let s) = key else { return nil }
            result[s] = val
        }
        return result
    }
}

extension SymmetricKey {
    /// Raw key bytes as `Data`.
    var rawData: Data {
        withUnsafeBytes { Data($0) }
    }
}
