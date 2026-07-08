import Foundation

/// Tag values used by HAP TLV8, matching pyatv's `TlvValue` (`hap_tlv8.py`)
/// and the `hapTlv8.ts` port, tag-for-tag.
public enum TLV8Tag: UInt8, Sendable, CaseIterable {
    case method = 0x00
    case identifier = 0x01
    case salt = 0x02
    case publicKey = 0x03
    case proof = 0x04
    case encryptedData = 0x05
    case sequence = 0x06
    case error = 0x07
    case backOff = 0x08
    case certificate = 0x09
    case signature = 0x0A
    case permissions = 0x0B
    case fragmentData = 0x0C
    case fragmentLast = 0x0D
    case name = 0x11
    case flags = 0x13
}

/// HAP TLV8 encode/decode, byte-exact with pyatv's `pyatv.auth.hap_tlv8`
/// (`read_tlv`/`write_tlv`) and the `hapTlv8.ts` port.
///
/// Note (matching pyatv, the canonical reference): a zero-length value
/// contributes no bytes at all to the encoded output -- pyatv's `write_tlv`
/// loop body never runs for an empty value, so the tag is silently dropped.
/// This differs from the TS port, which writes an explicit tag+0-length
/// entry for empty values; pyatv is treated as the source of truth here.
public enum TLV8 {
    /// Encode an ordered list of tag/value pairs into TLV8 bytes.
    ///
    /// Order is preserved exactly as given -- pyatv iterates dict entries in
    /// insertion order and the tests depend on byte-exact output, so this
    /// takes an ordered array rather than an unordered dictionary. Values
    /// longer than 255 bytes are split into consecutive 255-byte fragments
    /// that repeat the same tag.
    public static func encode(_ pairs: [(tag: UInt8, value: Data)]) -> Data {
        var out = Data()
        for (tag, value) in pairs {
            var remaining = value.count
            var pos = value.startIndex
            while remaining > 0 {
                let size = min(remaining, 255)
                let end = value.index(pos, offsetBy: size)
                out.append(tag)
                out.append(UInt8(size))
                out.append(value[pos..<end])
                pos = end
                remaining -= size
            }
        }
        return out
    }

    /// Convenience overload accepting the named `TLV8Tag` enum.
    public static func encode(_ pairs: [(tag: TLV8Tag, value: Data)]) -> Data {
        encode(pairs.map { (tag: $0.tag.rawValue, value: $0.value) })
    }

    /// Decode TLV8 bytes into a tag -> value map, merging the value bytes of
    /// repeated (fragmented) tags in the order they appear.
    public static func decode(_ data: Data) -> [UInt8: Data] {
        var result: [UInt8: Data] = [:]
        var pos = data.startIndex
        let end = data.endIndex

        while pos < end {
            let tag = data[pos]
            let lengthIndex = data.index(after: pos)
            guard lengthIndex < end else { break }
            let length = Int(data[lengthIndex])
            let valueStart = data.index(after: lengthIndex)
            let valueEnd = data.index(valueStart, offsetBy: length, limitedBy: end) ?? end
            let value = data[valueStart..<valueEnd]

            if let existing = result[tag] {
                result[tag] = existing + value
            } else {
                result[tag] = Data(value)
            }

            pos = valueEnd
        }

        return result
    }
}
