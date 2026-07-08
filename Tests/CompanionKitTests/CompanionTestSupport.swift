import CryptoKit
import Foundation
@testable import CompanionKit

/// In-memory, ordered byte pipe used to wire a `CompanionConnection` to a test
/// peer without touching the network. Chunk boundaries are preserved so tests
/// can exercise partial-frame delivery.
actor ByteChannel {
    private var chunks: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?
    private var closed = false

    func send(_ data: Data) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: data)
        } else {
            chunks.append(data)
        }
    }

    func receive() async throws -> Data {
        if !chunks.isEmpty { return chunks.removeFirst() }
        if closed { throw CompanionConnectionError.closed }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func close() {
        closed = true
        if let waiter {
            self.waiter = nil
            waiter.resume(throwing: CompanionConnectionError.closed)
        }
    }
}

/// A `CompanionTransport` backed by a pair of `ByteChannel`s.
struct MemoryTransport: CompanionTransport {
    let outbound: ByteChannel
    let inbound: ByteChannel

    func start(host: String, port: UInt16) async throws {}
    func send(_ data: Data) async throws { await outbound.send(data) }
    func receive() async throws -> Data { try await inbound.receive() }
    func close() async {
        await outbound.close()
        await inbound.close()
    }
}

/// Response builder: given a decoded request message, return the response
/// message's ordered pairs, or `nil` to send nothing.
typealias CompanionResponder = @Sendable ([String: OPACKValue]) -> [(String, OPACKValue)]?

/// Drives the accessory side of a full Companion connection over `ByteChannel`s:
/// answers Pair-Verify auth frames using `FakeCompanionServer`, enables
/// per-frame encryption once verified, and dispatches OPACK requests to a
/// user-supplied responder. Can also `emit` unsolicited events.
actor CompanionServerDriver {
    let server: FakeCompanionServer
    private let clientToServer: ByteChannel
    private let serverToClient: ByteChannel
    private var parser = CompanionFrameParser()
    private var session: CompanionSession?
    private let responder: CompanionResponder
    private var task: Task<Void, Never>?

    init(
        server: FakeCompanionServer,
        clientToServer: ByteChannel,
        serverToClient: ByteChannel,
        responder: @escaping CompanionResponder
    ) {
        self.server = server
        self.clientToServer = clientToServer
        self.serverToClient = serverToClient
        self.responder = responder
    }

    func startLoop() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func run() async {
        while !Task.isCancelled {
            let chunk: Data
            do { chunk = try await clientToServer.receive() } catch { break }
            parser.append(chunk)
            while let raw = parser.next() {
                await handle(raw)
            }
        }
    }

    private func handle(_ raw: RawFrame) async {
        guard let type = FrameType(rawValue: raw.typeByte) else { return }
        let payload: Data
        if let session, raw.payload.count > 0 {
            guard let decrypted = try? session.decrypt(raw.payload, aad: raw.header) else { return }
            payload = decrypted
        } else {
            payload = raw.payload
        }

        switch type {
        case .psStart, .psNext:
            // Pair-Setup runs plaintext (pre-encryption); route the `_pd` blob
            // through the fake accessory's Pair-Setup state machine.
            guard let dict = (try? OPACK.unpack(payload))?.asStringDictionary,
                  let pd = dict["_pd"]?.asData else { return }
            let responseTLV = (try? server.handlePairSetup(pd)) ?? Data()
            await sendFrame(.psNext, pairs: [("_pd", .data(responseTLV))])
        case .pvStart, .pvNext:
            guard let dict = (try? OPACK.unpack(payload))?.asStringDictionary,
                  let pd = dict["_pd"]?.asData else { return }
            let responseTLV = (try? server.handlePairVerify(pd)) ?? Data()
            await sendFrame(.pvNext, pairs: [("_pd", .data(responseTLV))])
            if type == .pvNext {
                // Enable server-side encryption *after* the plaintext M4.
                if let keys = try? server.companionSessionKeys() {
                    session = CompanionSession(outputKey: keys.server, inputKey: keys.client)
                }
            }
        case .uOPACK, .eOPACK, .pOPACK:
            guard let dict = (try? OPACK.unpack(payload))?.asStringDictionary else { return }
            if let responsePairs = responder(dict) {
                await sendFrame(type, pairs: responsePairs)
            }
        default:
            break
        }
    }

    /// Send an OPACK frame to the client, encrypting when a session is active.
    func emit(_ frameType: FrameType, pairs: [(String, OPACKValue)]) async {
        await sendFrame(frameType, pairs: pairs)
    }

    private func sendFrame(_ frameType: FrameType, pairs: [(String, OPACKValue)]) async {
        let dict = OPACKValue.dictionary(pairs.map { (OPACKValue.string($0.0), $0.1) })
        guard let opack = try? OPACK.pack(dict) else { return }
        var payload = opack
        var length = payload.count
        if session != nil, length > 0 { length += 16 }
        guard let header = try? CompanionFraming.header(
            typeByte: frameType.rawValue, payloadLength: length) else { return }
        if let session, payload.count > 0 {
            payload = (try? session.encrypt(payload, aad: header)) ?? payload
        }
        await serverToClient.send(header + payload)
    }
}
