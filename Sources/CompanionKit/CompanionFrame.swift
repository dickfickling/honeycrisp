import Foundation

/// Companion frame type values.
///
/// Byte-exact port of pyatv's `connection.py` `FrameType` enum (and the
/// identical `nodeatv` `FrameType`). The wire byte is the raw value; frames
/// are framed as a 4-byte header (1 byte type + 3 byte big-endian payload
/// length) followed by the payload.
public enum FrameType: UInt8, Sendable, CaseIterable {
    case unknown = 0
    case noOp = 1
    case psStart = 3
    case psNext = 4
    case pvStart = 5
    case pvNext = 6
    case uOPACK = 7
    case eOPACK = 8
    case pOPACK = 9
    case paReq = 10
    case paRsp = 11
    case sessionStartRequest = 16
    case sessionStartResponse = 17
    case sessionData = 18
    case familyIdentityRequest = 32
    case familyIdentityResponse = 33
    case familyIdentityUpdate = 34
}

/// A decoded Companion frame: a typed frame kind plus its (already decrypted,
/// where applicable) payload bytes.
public struct CompanionFrame: Sendable, Equatable {
    public let type: FrameType
    public let payload: Data

    public init(type: FrameType, payload: Data) {
        self.type = type
        self.payload = payload
    }
}

/// Errors raised by the Companion framing layer.
public enum CompanionFrameError: Error, Equatable, Sendable {
    /// A payload longer than the 3-byte length field can express (2^24 - 1).
    case payloadTooLarge(Int)
}

/// Low-level header helpers, matching pyatv `connection.py`
/// (`HEADER_LENGTH = 4`, `bytes([type]) + length.to_bytes(3, "big")`).
public enum CompanionFraming {
    public static let headerLength = 4
    /// Largest payload length expressible in the 3-byte big-endian length
    /// field.
    public static let maxPayloadLength = 0xFF_FFFF

    /// Encode a 4-byte frame header for the given type byte and payload
    /// length.
    ///
    /// - Throws: `CompanionFrameError.payloadTooLarge` when `payloadLength`
    ///   exceeds `maxPayloadLength`.
    public static func header(typeByte: UInt8, payloadLength: Int) throws -> Data {
        guard payloadLength >= 0, payloadLength <= maxPayloadLength else {
            throw CompanionFrameError.payloadTooLarge(payloadLength)
        }
        var header = Data(count: headerLength)
        header[0] = typeByte
        header[1] = UInt8((payloadLength >> 16) & 0xFF)
        header[2] = UInt8((payloadLength >> 8) & 0xFF)
        header[3] = UInt8(payloadLength & 0xFF)
        return header
    }
}

/// A frame extracted straight off the wire before any decryption: the exact
/// 4-byte header (needed verbatim as ChaCha20-Poly1305 AAD), the type byte,
/// and the raw (possibly still-encrypted) payload.
public struct RawFrame: Equatable, Sendable {
    public let header: Data
    public let typeByte: UInt8
    public let payload: Data
}

/// Incremental TCP stream parser: accumulate arbitrary byte chunks and pop
/// off complete frames as they become available.
///
/// Mirrors pyatv's `data_received` buffering loop: keep a rolling buffer, and
/// while it holds a full header plus the declared payload, slice out one
/// frame. Payloads up to `CompanionFraming.maxPayloadLength` (2^24 - 1) are
/// supported.
public struct CompanionFrameParser: Sendable {
    private var buffer = Data()

    public init() {}

    /// Append newly received bytes to the internal buffer.
    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Pop the next complete frame, or `nil` if the buffer does not yet hold
    /// one.
    public mutating func next() -> RawFrame? {
        guard buffer.count >= CompanionFraming.headerLength else { return nil }

        // `buffer` may have a non-zero startIndex after slicing; index via the
        // start offset so this is correct regardless.
        let start = buffer.startIndex
        let b1 = Int(buffer[start + 1])
        let b2 = Int(buffer[start + 2])
        let b3 = Int(buffer[start + 3])
        let payloadLength = (b1 << 16) | (b2 << 8) | b3
        let total = CompanionFraming.headerLength + payloadLength

        guard buffer.count >= total else { return nil }

        let header = Data(buffer[start ..< start + CompanionFraming.headerLength])
        let payload = Data(buffer[start + CompanionFraming.headerLength ..< start + total])
        let typeByte = header[header.startIndex]

        buffer.removeSubrange(start ..< start + total)

        return RawFrame(header: header, typeByte: typeByte, payload: payload)
    }
}
