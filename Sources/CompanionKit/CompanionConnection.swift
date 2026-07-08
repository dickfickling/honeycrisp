import Foundation
import Network

/// Errors surfaced by the Companion transport / connection layer.
public enum CompanionConnectionError: Error, Equatable, Sendable {
    /// A send/receive was attempted before `connect(host:port:)`.
    case notConnected
    /// The remote end closed the connection (clean EOF).
    case closed
    /// The underlying transport reported a failure.
    case transportFailed(String)
}

/// Byte-stream transport abstraction behind `CompanionConnection`.
///
/// A production `NWCompanionTransport` (over `NWConnection`/TCP) ships here;
/// tests substitute an in-memory implementation. `receive()` returns the next
/// available chunk of bytes and throws `CompanionConnectionError.closed` at
/// end of stream.
public protocol CompanionTransport: Sendable {
    func start(host: String, port: UInt16) async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
}

/// Actor owning the transport, incremental framing, and (once enabled)
/// per-frame encryption for a single Companion connection.
///
/// Port of pyatv's `CompanionConnection` (`connection.py`): a rolling receive
/// buffer feeds a frame parser; complete frames are decrypted (when a session
/// is active and the payload is non-empty) and published on `frames`.
/// Outbound frames are encrypted symmetrically, with the 4-byte header used as
/// ChaCha20-Poly1305 AAD and its length field reflecting the +16 tag.
public actor CompanionConnection {
    private let transport: CompanionTransport
    private var parser = CompanionFrameParser()
    private var session: CompanionSession?
    private var readTask: Task<Void, Never>?
    private var isConnected = false

    private let frameStream: AsyncStream<CompanionFrame>
    private let frameContinuation: AsyncStream<CompanionFrame>.Continuation

    /// Stream of frames received (and decrypted, where applicable) from the
    /// remote device. Finishes when the connection closes.
    public nonisolated var frames: AsyncStream<CompanionFrame> { frameStream }

    public init(transport: CompanionTransport) {
        self.transport = transport
        (self.frameStream, self.frameContinuation) = AsyncStream.makeStream(of: CompanionFrame.self)
    }

    /// Open the transport and begin reading frames.
    public func connect(host: String, port: UInt16) async throws {
        try await transport.start(host: host, port: port)
        isConnected = true
        startReadLoop()
    }

    /// Enable per-frame encryption using directional keys derived from
    /// Pair-Verify (pyatv `enable_encryption`).
    public func enableEncryption(outputKey: Data, inputKey: Data) {
        session = CompanionSession(outputKey: outputKey, inputKey: inputKey)
    }

    /// Send a frame, encrypting the payload if a session is active and the
    /// payload is non-empty (matching pyatv `send`).
    public func send(frame: CompanionFrame) async throws {
        guard isConnected else { throw CompanionConnectionError.notConnected }

        var payload = frame.payload
        var payloadLength = payload.count
        if session != nil, payloadLength > 0 {
            payloadLength += 16 // Poly1305 tag
        }
        let header = try CompanionFraming.header(
            typeByte: frame.type.rawValue, payloadLength: payloadLength)

        if let session, payload.count > 0 {
            payload = try session.encrypt(payload, aad: header)
        }

        try await transport.send(header + payload)
    }

    /// Close the connection and finish the `frames` stream.
    public func close() async {
        isConnected = false
        readTask?.cancel()
        readTask = nil
        await transport.close()
        frameContinuation.finish()
    }

    private func startReadLoop() {
        guard readTask == nil else { return }
        readTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    private func readLoop() async {
        while !Task.isCancelled {
            let chunk: Data
            do {
                chunk = try await transport.receive()
            } catch {
                break
            }
            parser.append(chunk)
            drainFrames()
        }
        frameContinuation.finish()
    }

    private func drainFrames() {
        while let raw = parser.next() {
            let payload: Data
            if let session, raw.payload.count > 0 {
                do {
                    payload = try session.decrypt(raw.payload, aad: raw.header)
                } catch {
                    // pyatv logs and drops undecryptable frames.
                    continue
                }
            } else {
                payload = raw.payload
            }
            guard let type = FrameType(rawValue: raw.typeByte) else {
                // Unknown frame type: pyatv raises inside its handler and drops.
                continue
            }
            frameContinuation.yield(CompanionFrame(type: type, payload: payload))
        }
    }
}

/// One-shot latch so an `NWConnection.stateUpdateHandler` (called repeatedly
/// on the connection's serial queue) resumes its setup continuation exactly
/// once. `@unchecked Sendable`: the flag is guarded by an internal lock.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    /// Returns `true` exactly once (the first call).
    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

/// Production `CompanionTransport` over `NWConnection` (TCP).
///
/// `@unchecked Sendable`: all mutable state is confined to callbacks scheduled
/// on the connection's serial `DispatchQueue`, and cross-task access is
/// mediated by continuations.
public final class NWCompanionTransport: CompanionTransport, @unchecked Sendable {
    private let queue = DispatchQueue(label: "companion.transport")
    private var connection: NWConnection?

    public init() {}

    public func start(host: String, port: UInt16) async throws {
        let nwHost = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw CompanionConnectionError.transportFailed("invalid port \(port)")
        }
        let params = NWParameters.tcp
        let connection = NWConnection(host: nwHost, port: nwPort, using: params)
        self.connection = connection

        let once = OnceFlag()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.take() { cont.resume() }
                case .failed(let error), .waiting(let error):
                    if once.take() {
                        // Stop the connection's background retrying; otherwise
                        // an abandoned NWConnection keeps probing forever.
                        connection.cancel()
                        cont.resume(throwing: CompanionConnectionError.transportFailed(
                            error.localizedDescription))
                    }
                case .cancelled:
                    if once.take() {
                        cont.resume(throwing: CompanionConnectionError.closed)
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    public func send(_ data: Data) async throws {
        guard let connection else { throw CompanionConnectionError.notConnected }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: CompanionConnectionError.transportFailed(
                        error.localizedDescription))
                } else {
                    cont.resume()
                }
            })
        }
    }

    public func receive() async throws -> Data {
        guard let connection else { throw CompanionConnectionError.notConnected }
        return try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                data, _, isComplete, error in
                if let error {
                    cont.resume(throwing: CompanionConnectionError.transportFailed(
                        error.localizedDescription))
                } else if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if isComplete {
                    cont.resume(throwing: CompanionConnectionError.closed)
                } else {
                    cont.resume(throwing: CompanionConnectionError.closed)
                }
            }
        }
    }

    public func close() async {
        connection?.cancel()
        connection = nil
    }
}
