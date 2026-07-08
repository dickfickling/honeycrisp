import Foundation

/// Drives HAP Pair-Setup over an unauthenticated Companion connection to mint
/// new `HAPCredentials`.
///
/// Port of pyatv's `CompanionPairSetupProcedure` (`companion/auth.py`): the M1
/// method/seqno blob is exchanged over a `PS_Start` frame; the remaining
/// messages (M3 public-key+proof, M5 encrypted device info) go over `PS_Next`.
/// Each auth frame carries the pairing-data TLV under `_pd` alongside
/// `_pwTy: 1`.
///
/// Deviation from the brief wording: the brief mentions `_auTy` for pair-setup,
/// but pyatv sends `_pwTy: 1` on `PS_*` frames (`_auTy: 4` is the *Pair-Verify*
/// field). pyatv wire behavior wins, so this uses `_pwTy: 1`.
public actor CompanionPairer {
    private let host: String
    private let port: UInt16
    private let transport: CompanionTransport
    private let signingSeed: Data?
    private let pairingId: Data?
    private let displayName: String?

    private var connection: CompanionConnection?
    private var proto: CompanionProtocolLayer?
    /// The accessory's M2 pairing-data blob (salt + SRP public key), captured
    /// by `begin()` and consumed by `finish(pin:)`.
    private var atvM2: Data?

    /// Errors surfaced by the pairing orchestration.
    public enum PairerError: Error, Equatable, Sendable {
        /// `finish(pin:)` was called before a successful `begin()`.
        case notStarted
    }

    /// - Parameters:
    ///   - signingSeed: 32-byte Ed25519 seed for the controller identity
    ///     (injected for deterministic tests); random if omitted.
    ///   - pairingId: controller identifier bytes; a random UUID if omitted.
    ///   - displayName: optional controller name embedded in the M5 device info.
    public init(
        host: String,
        port: UInt16,
        transport: CompanionTransport = NWCompanionTransport(),
        signingSeed: Data? = nil,
        pairingId: Data? = nil,
        displayName: String? = nil
    ) {
        self.host = host
        self.port = port
        self.transport = transport
        self.signingSeed = signingSeed
        self.pairingId = pairingId
        self.displayName = displayName
    }

    /// Open the connection and send Pair-Setup M1, prompting the device to show
    /// its PIN.
    ///
    /// - Returns: `true` — a Companion accessory always displays a PIN for
    ///   Pair-Setup (there is no PIN-less path). Returned as a `Bool` so callers
    ///   can branch uniformly on device types that may not.
    @discardableResult
    public func begin() async throws -> Bool {
        let conn = CompanionConnection(transport: transport)
        let proto = CompanionProtocolLayer(connection: conn)
        try await conn.connect(host: host, port: port)
        self.connection = conn
        self.proto = proto

        do {
            // M1: {Method: 0x00, SeqNo: 0x01} — identical to PairSetup.m1() and
            // independent of the (not-yet-known) PIN.
            let m1 = TLV8.encode([
                (TLV8Tag.method, Data([0x00])),
                (TLV8Tag.sequence, Data([0x01])),
            ])
            let resp = try await proto.exchangeAuth(
                .psStart,
                [("_pd", .data(m1)), ("_pwTy", .int(1))],
                responseType: .psNext)
            guard let m2 = resp["_pd"]?.asData else {
                throw CompanionProtocolError.missingField("_pd")
            }
            self.atvM2 = m2
            return true
        } catch {
            // Don't leak the open connection when the M1/M2 exchange fails.
            await closeConnection()
            throw error
        }
    }

    /// Complete Pair-Setup with the PIN shown on screen and return the derived
    /// credentials. Closes the connection when finished (success or failure).
    ///
    /// - Throws: `PairingError.deviceError(0x02)` on a wrong PIN (the accessory
    ///   returns a TLV authentication error at M4).
    public func finish(pin: Int) async throws -> HAPCredentials {
        guard let proto, let m2 = atvM2 else { throw PairerError.notStarted }
        defer { Task { await closeConnection() } }

        let setup = PairSetup(
            pin: pin,
            displayName: displayName,
            signingSeed: signingSeed,
            pairingId: pairingId)

        // M3: client public key + proof.
        let m3 = try setup.handleM2AndBuildM3(m2)
        let m4Resp = try await proto.exchangeAuth(
            .psNext,
            [("_pd", .data(m3)), ("_pwTy", .int(1))],
            responseType: .psNext)
        guard let m4 = m4Resp["_pd"]?.asData else {
            throw CompanionProtocolError.missingField("_pd")
        }

        // M5: verify the accessory proof (raises on wrong PIN) and build the
        // encrypted controller device info.
        let m5 = try setup.handleM4AndBuildM5(m4)
        let m6Resp = try await proto.exchangeAuth(
            .psNext,
            [("_pd", .data(m5)), ("_pwTy", .int(1))],
            responseType: .psNext)
        guard let m6 = m6Resp["_pd"]?.asData else {
            throw CompanionProtocolError.missingField("_pd")
        }

        // M6: decrypt the accessory device info and assemble credentials.
        return try setup.handleM6(m6)
    }

    /// Close the underlying connection, abandoning any in-progress pairing.
    public func cancel() async {
        await closeConnection()
    }

    private func closeConnection() async {
        await connection?.close()
        connection = nil
        proto = nil
        atvM2 = nil
    }
}
