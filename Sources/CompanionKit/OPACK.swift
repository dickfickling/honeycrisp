import Foundation

/// Errors that can be produced while packing or unpacking OPACK data.
///
/// Mirrors the error conditions raised by pyatv's `pyatv.support.opack`
/// (`TypeError` for unsupported/unknown wire tags, `NotImplementedError` for
/// absolute time) translated to idiomatic Swift errors.
public enum OPACKError: Error, Equatable, Sendable {
    /// A feature that pyatv also does not implement (absolute time, tag 0x06 on pack).
    case notImplemented(String)
    /// An unknown/unsupported leading tag byte was encountered while decoding.
    case unsupportedTag(UInt8)
    /// The input ended before a complete value could be decoded.
    case truncatedData
    /// A string value's bytes were not valid UTF-8.
    case invalidUTF8
    /// A backreference pointer referred to an object list index that does not exist.
    case invalidReference
}

extension OPACKError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notImplemented(let what):
            return "not implemented: \(what)"
        case .unsupportedTag(let tag):
            return String(format: "unsupported tag: 0x%02x", tag)
        case .truncatedData:
            return "truncated OPACK data"
        case .invalidUTF8:
            return "invalid UTF-8 in OPACK string"
        case .invalidReference:
            return "invalid OPACK backreference"
        }
    }
}

/// A decoded (or to-be-encoded) OPACK value.
///
/// OPACK is Apple's binary serialization format used by the Companion and
/// related protocols. This models every wire type pyatv's `opack.py` and the
/// `opack.ts` port support: nil, bool, packed/sized integers, floats, UTF-8
/// strings, raw byte strings, arrays (including the "endless" wire form),
/// dictionaries (including "endless"), and UUID.
///
/// Dictionary keys are not restricted to strings on the wire (pyatv allows
/// e.g. a bool key), so `.dictionary` preserves an ordered list of pairs
/// rather than using `Dictionary`, which also lets pack/unpack round-trip
/// preserve insertion/wire order exactly.
public enum OPACKValue: Equatable, Sendable {
    case null
    case bool(Bool)
    /// An integer value. `sizeHint` records the wire width (1, 2, 4 or 8
    /// bytes) it was decoded with, if any, mirroring pyatv's `_sized_int`,
    /// so re-encoding an unmodified decoded value reproduces the same
    /// byte width. `nil` means "pick the canonical smallest encoding",
    /// matching a plain Python `int`.
    case int(UInt64, sizeHint: Int?)
    case double(Double)
    case string(String)
    case data(Data)
    case uuid(UUID)
    /// Absolute time (wire tag 0x06). Neither pyatv nor the TS port
    /// implement packing this; see `OPACK.pack` for the resulting error.
    case absoluteTime(Date)
    case array([OPACKValue])
    case dictionary([(OPACKValue, OPACKValue)])

    /// Convenience for constructing a plain (no size hint) integer value.
    public static func int(_ value: UInt64) -> OPACKValue {
        .int(value, sizeHint: nil)
    }

    public static func == (lhs: OPACKValue, rhs: OPACKValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):
            return true
        case (.bool(let a), .bool(let b)):
            return a == b
        case (.int(let a, _), .int(let b, _)):
            // pyatv's `_sized_int` is a plain `int` subclass; its `.size`
            // attribute does not participate in equality/hashing, so two
            // integers with the same value but different size hints are
            // considered equal, matching Python semantics.
            return a == b
        case (.double(let a), .double(let b)):
            return a == b
        case (.string(let a), .string(let b)):
            return a == b
        case (.data(let a), .data(let b)):
            return a == b
        case (.uuid(let a), .uuid(let b)):
            return a == b
        case (.absoluteTime(let a), .absoluteTime(let b)):
            return a == b
        case (.array(let a), .array(let b)):
            return a == b
        case (.dictionary(let a), .dictionary(let b)):
            guard a.count == b.count else { return false }
            for i in 0..<a.count where a[i].0 != b[i].0 || a[i].1 != b[i].1 {
                return false
            }
            return true
        default:
            return false
        }
    }
}

// MARK: - Literal conveniences

extension OPACKValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension OPACKValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension OPACKValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: UInt64) { self = .int(value, sizeHint: nil) }
}

extension OPACKValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension OPACKValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension OPACKValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: OPACKValue...) { self = .array(elements) }
}

extension OPACKValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (OPACKValue, OPACKValue)...) {
        self = .dictionary(elements)
    }
}

/// Apple OPACK binary serialization: pack Swift values to wire bytes and
/// back, byte-exact with pyatv's `pyatv.support.opack` (canonical) and the
/// `opack.ts` typed port.
public enum OPACK {
    /// Pack a value into its canonical OPACK wire encoding.
    ///
    /// - Throws: `OPACKError.notImplemented` for `.absoluteTime`, matching
    ///   both reference implementations (they raise on packing a
    ///   `datetime`/`Date`).
    public static func pack(_ value: OPACKValue) throws -> Data {
        var objectList: [Data] = []
        return try packValue(value, objectList: &objectList)
    }

    /// Unpack a single OPACK value from the front of `data`.
    ///
    /// Any bytes after the first complete value are ignored, matching
    /// pyatv's `unpack`, which returns `(value, remaining)` and leaves it to
    /// the caller to decide whether trailing bytes matter.
    public static func unpack(_ data: Data) throws -> OPACKValue {
        var reader = Reader(bytes: [UInt8](data))
        var objectList: [OPACKValue] = []
        return try unpackValue(&reader, &objectList)
    }

    // MARK: Packing

    private static func packValue(_ value: OPACKValue, objectList: inout [Data]) throws -> Data {
        var packed: Data

        switch value {
        case .null:
            packed = Data([0x04])
        case .bool(let b):
            packed = Data([b ? 0x01 : 0x02])
        case .uuid(let u):
            packed = Data([0x05]) + uuidBytes(u)
        case .absoluteTime:
            throw OPACKError.notImplemented("absolute time")
        case .int(let n, let sizeHint):
            packed = packInt(n, sizeHint: sizeHint)
        case .double(let d):
            packed = Data([0x36]) + leBytes(d.bitPattern, 8)
        case .string(let s):
            packed = packString(s)
        case .data(let d):
            packed = packBytes(d)
        case .array(let items):
            var out = Data([UInt8(0xD0 + min(items.count, 0xF))])
            for item in items {
                out.append(try packValue(item, objectList: &objectList))
            }
            if items.count >= 0xF {
                out.append(0x03)
            }
            packed = out
        case .dictionary(let pairs):
            var out = Data([UInt8(0xE0 + min(pairs.count, 0xF))])
            for (k, v) in pairs {
                out.append(try packValue(k, objectList: &objectList))
                out.append(try packValue(v, objectList: &objectList))
            }
            if pairs.count >= 0xF {
                out.append(0x03)
            }
            packed = out
        }

        // Object-list (pointer) referencing: reuse a previous identical
        // encoding via a backreference instead of repeating it, exactly as
        // pyatv's `_pack` does.
        if let index = objectList.firstIndex(of: packed) {
            packed = pointerBytes(for: index)
        } else if packed.count > 1 {
            objectList.append(packed)
        }

        return packed
    }

    private static func packInt(_ n: UInt64, sizeHint: Int?) -> Data {
        if n < 0x28 && sizeHint == nil {
            return Data([UInt8(n) + 8])
        }
        if (n <= 0xFF && sizeHint == nil) || sizeHint == 1 {
            return Data([0x30]) + leBytes(n, 1)
        }
        if (n <= 0xFFFF && sizeHint == nil) || sizeHint == 2 {
            return Data([0x31]) + leBytes(n, 2)
        }
        if (n <= 0xFFFF_FFFF && sizeHint == nil) || sizeHint == 4 {
            return Data([0x32]) + leBytes(n, 4)
        }
        return Data([0x33]) + leBytes(n, 8)
    }

    private static func packString(_ s: String) -> Data {
        let encoded = Data(s.utf8)
        let len = encoded.count
        if len <= 0x20 {
            return Data([UInt8(0x40 + len)]) + encoded
        } else if len <= 0xFF {
            return Data([0x61]) + leBytes(UInt64(len), 1) + encoded
        } else if len <= 0xFFFF {
            return Data([0x62]) + leBytes(UInt64(len), 2) + encoded
        } else if len <= 0xFF_FFFF {
            return Data([0x63]) + leBytes(UInt64(len), 3) + encoded
        } else {
            return Data([0x64]) + leBytes(UInt64(len), 4) + encoded
        }
    }

    private static func packBytes(_ d: Data) -> Data {
        let len = d.count
        if len <= 0x20 {
            return Data([UInt8(0x70 + len)]) + d
        } else if len <= 0xFF {
            return Data([0x91]) + leBytes(UInt64(len), 1) + d
        } else if len <= 0xFFFF {
            return Data([0x92]) + leBytes(UInt64(len), 2) + d
        } else if len <= 0xFFFF_FFFF {
            return Data([0x93]) + leBytes(UInt64(len), 4) + d
        } else {
            return Data([0x94]) + leBytes(UInt64(len), 8) + d
        }
    }

    private static func pointerBytes(for index: Int) -> Data {
        if index < 0x21 {
            return Data([UInt8(0xA0 + index)])
        } else if index <= 0xFF {
            return Data([0xC1]) + leBytes(UInt64(index), 1)
        } else if index <= 0xFFFF {
            return Data([0xC2]) + leBytes(UInt64(index), 2)
        } else if index <= 0xFFFF_FFFF {
            return Data([0xC3]) + leBytes(UInt64(index), 4)
        } else {
            return Data([0xC4]) + leBytes(UInt64(index), 8)
        }
    }

    private static func uuidBytes(_ u: UUID) -> Data {
        withUnsafeBytes(of: u.uuid) { Data($0) }
    }

    private static func leBytes(_ n: UInt64, _ count: Int) -> Data {
        var value = n
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        for _ in 0..<count {
            bytes.append(UInt8(value & 0xFF))
            value >>= 8
        }
        return Data(bytes)
    }

    // MARK: Unpacking

    private struct Reader {
        let bytes: [UInt8]
        var pos: Int = 0

        func peek() throws -> UInt8 {
            guard pos < bytes.count else { throw OPACKError.truncatedData }
            return bytes[pos]
        }

        mutating func readByte() throws -> UInt8 {
            let b = try peek()
            pos += 1
            return b
        }

        mutating func readBytes(_ n: Int) throws -> [UInt8] {
            // `n <= bytes.count - pos` rather than `pos + n <= bytes.count`:
            // a hostile length near Int.max would make the addition trap.
            guard n >= 0, n <= bytes.count - pos else { throw OPACKError.truncatedData }
            let slice = Array(bytes[pos..<(pos + n)])
            pos += n
            return slice
        }
    }

    private static func unpackValue(
        _ reader: inout Reader, _ objectList: inout [OPACKValue]
    ) throws -> OPACKValue {
        let tag = try reader.readByte()
        var value: OPACKValue
        var addToObjectList = true

        switch tag {
        case 0x01:
            value = .bool(true)
            addToObjectList = false
        case 0x02:
            value = .bool(false)
            addToObjectList = false
        case 0x04:
            value = .null
            addToObjectList = false
        case 0x05:
            value = .uuid(uuidFromBytes(try reader.readBytes(16)))
        case 0x06:
            // Absolute time: not implemented by either reference on decode
            // either -- both parse it as a plain little-endian integer.
            value = .int(leToUInt64(try reader.readBytes(8)), sizeHint: nil)
        case 0x08...0x2F:
            value = .int(UInt64(tag - 8), sizeHint: nil)
            addToObjectList = false
        case 0x35:
            let bits = leToUInt32(try reader.readBytes(4))
            value = .double(Double(Float(bitPattern: bits)))
        case 0x36:
            let bits = leToUInt64(try reader.readBytes(8))
            value = .double(Double(bitPattern: bits))
        default:
            if (tag & 0xF0) == 0x30 {
                let nBytes = 1 << Int(tag & 0x0F)
                let n = leToUInt64(try reader.readBytes(nBytes))
                value = .int(n, sizeHint: nBytes)
            } else if tag >= 0x40 && tag <= 0x60 {
                let length = Int(tag) - 0x40
                value = .string(try decodeUTF8(try reader.readBytes(length)))
            } else if tag > 0x60 && tag <= 0x64 {
                let nBytes = Int(tag & 0x0F)
                let length = try readLength(&reader, bytes: nBytes)
                value = .string(try decodeUTF8(try reader.readBytes(length)))
            } else if tag >= 0x70 && tag <= 0x90 {
                let length = Int(tag) - 0x70
                value = .data(Data(try reader.readBytes(length)))
            } else if tag >= 0x91 && tag <= 0x94 {
                let nBytes = 1 << (Int(tag & 0x0F) - 1)
                let length = try readLength(&reader, bytes: nBytes)
                value = .data(Data(try reader.readBytes(length)))
            } else if (tag & 0xF0) == 0xD0 {
                let count = Int(tag & 0x0F)
                var items: [OPACKValue] = []
                if count == 0xF {
                    while try reader.peek() != 0x03 {
                        items.append(try unpackValue(&reader, &objectList))
                    }
                    _ = try reader.readByte()
                } else {
                    for _ in 0..<count {
                        items.append(try unpackValue(&reader, &objectList))
                    }
                }
                value = .array(items)
                addToObjectList = false
            } else if (tag & 0xE0) == 0xE0 {
                let count = Int(tag & 0x0F)
                var pairs: [(OPACKValue, OPACKValue)] = []
                if count == 0xF {
                    while try reader.peek() != 0x03 {
                        let k = try unpackValue(&reader, &objectList)
                        let v = try unpackValue(&reader, &objectList)
                        pairs.append((k, v))
                    }
                    _ = try reader.readByte()
                } else {
                    for _ in 0..<count {
                        let k = try unpackValue(&reader, &objectList)
                        let v = try unpackValue(&reader, &objectList)
                        pairs.append((k, v))
                    }
                }
                value = .dictionary(pairs)
                addToObjectList = false
            } else if tag >= 0xA0 && tag <= 0xC0 {
                let index = Int(tag) - 0xA0
                guard index < objectList.count else { throw OPACKError.invalidReference }
                value = objectList[index]
            } else if tag >= 0xC1 && tag <= 0xC4 {
                let length = Int(tag) - 0xC0
                let index = Int(leToUInt64(try reader.readBytes(length)))
                guard index < objectList.count else { throw OPACKError.invalidReference }
                value = objectList[index]
            } else {
                throw OPACKError.unsupportedTag(tag)
            }
        }

        if addToObjectList && !objectList.contains(value) {
            objectList.append(value)
        }

        return value
    }

    /// Read a little-endian length prefix, rejecting values that don't fit in
    /// Int (a wire length >= 2^63 would otherwise trap the Int(_:) conversion —
    /// remotely triggerable during the plaintext pairing phase).
    private static func readLength(_ reader: inout Reader, bytes nBytes: Int) throws -> Int {
        guard let length = Int(exactly: leToUInt64(try reader.readBytes(nBytes))) else {
            throw OPACKError.truncatedData
        }
        return length
    }

    private static func decodeUTF8(_ bytes: [UInt8]) throws -> String {
        guard let s = String(bytes: bytes, encoding: .utf8) else {
            throw OPACKError.invalidUTF8
        }
        return s
    }

    private static func uuidFromBytes(_ bytes: [UInt8]) -> UUID {
        let u: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: u)
    }

    private static func leToUInt64(_ bytes: [UInt8]) -> UInt64 {
        var result: UInt64 = 0
        for (i, b) in bytes.enumerated() {
            result |= UInt64(b) << (8 * i)
        }
        return result
    }

    private static func leToUInt32(_ bytes: [UInt8]) -> UInt32 {
        var result: UInt32 = 0
        for (i, b) in bytes.enumerated() {
            result |= UInt32(b) << (8 * i)
        }
        return result
    }
}
