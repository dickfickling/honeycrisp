import Foundation
import Testing
@testable import CompanionKit

/// Port of pyatv's `tests/auth/test_hap_tlv8.py` (canonical reference).
/// `stringify` and the `Method`/`ErrorCode`/`State`/`Flags` helper enums it
/// depends on are out of scope for this task's TLV8 codec and are not
/// ported here.
@Suite struct TLV8Tests {
    static let singleKeyOut = hexData("0a03313233")
    static let doubleKeyOut = hexData("0103313131 0403323232")
    static let largeKeyOut = hexData("02ff") + Data(repeating: 0x31, count: 255) + hexData("020131")

    @Test func writeSingleKey() {
        #expect(TLV8.encode([(tag: UInt8(10), value: Data("123".utf8))]) == Self.singleKeyOut)
    }

    @Test func writeTwoKeys() {
        let encoded = TLV8.encode([
            (tag: UInt8(1), value: Data("111".utf8)),
            (tag: UInt8(4), value: Data("222".utf8)),
        ])
        #expect(encoded == Self.doubleKeyOut)
    }

    @Test func writeKeyLargerThan255Bytes() {
        // This results in two serialized TLVs: one 255 bytes, the next
        // containing the remaining 1 byte.
        let value = Data(repeating: 0x31, count: 256)
        #expect(TLV8.encode([(tag: UInt8(2), value: value)]) == Self.largeKeyOut)
    }

    @Test func readSingleKey() {
        let result = TLV8.decode(Self.singleKeyOut)
        #expect(result[10] == Data("123".utf8))
        #expect(result.count == 1)
    }

    @Test func readTwoKeys() {
        let result = TLV8.decode(Self.doubleKeyOut)
        #expect(result[1] == Data("111".utf8))
        #expect(result[4] == Data("222".utf8))
        #expect(result.count == 2)
    }

    @Test func readKeyLargerThan255Bytes() {
        let result = TLV8.decode(Self.largeKeyOut)
        #expect(result[2] == Data(repeating: 0x31, count: 256))
        #expect(result.count == 1)
    }

    @Test func tagEnumMatchesPyatv() {
        // TlvValue in hap_tlv8.py, tag-for-tag.
        #expect(TLV8Tag.method.rawValue == 0x00)
        #expect(TLV8Tag.identifier.rawValue == 0x01)
        #expect(TLV8Tag.salt.rawValue == 0x02)
        #expect(TLV8Tag.publicKey.rawValue == 0x03)
        #expect(TLV8Tag.proof.rawValue == 0x04)
        #expect(TLV8Tag.encryptedData.rawValue == 0x05)
        #expect(TLV8Tag.sequence.rawValue == 0x06)
        #expect(TLV8Tag.error.rawValue == 0x07)
        #expect(TLV8Tag.backOff.rawValue == 0x08)
        #expect(TLV8Tag.certificate.rawValue == 0x09)
        #expect(TLV8Tag.signature.rawValue == 0x0A)
        #expect(TLV8Tag.permissions.rawValue == 0x0B)
        #expect(TLV8Tag.fragmentData.rawValue == 0x0C)
        #expect(TLV8Tag.fragmentLast.rawValue == 0x0D)
        #expect(TLV8Tag.name.rawValue == 0x11)
        #expect(TLV8Tag.flags.rawValue == 0x13)
    }

    @Test func encodeWithNamedTagsMatchesRawTags() {
        let named = TLV8.encode([(tag: TLV8Tag.identifier, value: Data("abc".utf8))])
        let raw = TLV8.encode([(tag: UInt8(1), value: Data("abc".utf8))])
        #expect(named == raw)
    }

    @Test func encodePreservesInsertionOrder() {
        // Same keys/values as writeTwoKeys but reversed order must produce
        // reversed wire bytes -- order is not normalized.
        let encoded = TLV8.encode([
            (tag: UInt8(4), value: Data("222".utf8)),
            (tag: UInt8(1), value: Data("111".utf8)),
        ])
        #expect(encoded == hexData("0403323232 0103313131"))
    }
}
