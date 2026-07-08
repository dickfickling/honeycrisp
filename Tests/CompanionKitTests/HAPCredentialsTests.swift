import Foundation
import Testing
@testable import CompanionKit

/// HAPCredentials wraps the wire-relevant subset of pyatv's `HapCredentials`
/// (`pyatv.auth.hap_pairing`): the `ltpk:ltsk:atv_id:client_id` hex string
/// format from `parse_credentials`/`HapCredentials.__str__`. There is no
/// dedicated upstream test file for this piece, so these vectors are
/// constructed directly from the documented format rather than ported
/// verbatim.
@Suite struct HAPCredentialsTests {
    static let ltpkHex = "0102030405060708090a0b0c0d0e0f10"
    static let ltskHex = "1112131415161718191a1b1c1d1e1f20"
    static let atvIdHex = "aabbccddeeff"
    static let clientIdHex = "001122334455"
    static let fullString = "\(ltpkHex):\(ltskHex):\(atvIdHex):\(clientIdHex)"

    @Test func parsesFourFieldHexString() throws {
        let creds = try HAPCredentials(string: Self.fullString)
        #expect(creds.ltpk == hexData(Self.ltpkHex))
        #expect(creds.ltsk == hexData(Self.ltskHex))
        #expect(creds.atvId == hexData(Self.atvIdHex))
        #expect(creds.clientId == hexData(Self.clientIdHex))
    }

    @Test func stringValueRoundTripsByteExact() throws {
        let creds = try HAPCredentials(string: Self.fullString)
        #expect(creds.stringValue == Self.fullString)
    }

    @Test func stringValueLowercasesHex() throws {
        let upper = Self.fullString.uppercased()
        let creds = try HAPCredentials(string: upper)
        // binascii.hexlify (and Buffer#toString("hex")) always produce
        // lowercase, regardless of the case of the input.
        #expect(creds.stringValue == Self.fullString)
    }

    @Test func supportsEmptyFields() throws {
        let creds = try HAPCredentials(string: "::aabb:")
        #expect(creds.ltpk.isEmpty)
        #expect(creds.ltsk.isEmpty)
        #expect(creds.atvId == hexData("aabb"))
        #expect(creds.clientId.isEmpty)
        #expect(creds.stringValue == "::aabb:")
    }

    @Test func directInitRoundTripsThroughStringValue() throws {
        let creds = HAPCredentials(
            ltpk: hexData(Self.ltpkHex),
            ltsk: hexData(Self.ltskHex),
            atvId: hexData(Self.atvIdHex),
            clientId: hexData(Self.clientIdHex)
        )
        #expect(creds.stringValue == Self.fullString)
        #expect(try HAPCredentials(string: creds.stringValue) == creds)
    }

    @Test func throwsOnWrongFieldCount() {
        // pyatv's parse_credentials raises InvalidCredentialsError unless
        // there are exactly 4 fields (the 2-field "legacy" form is out of
        // scope for this codec).
        #expect(throws: HAPCredentialsError.self) {
            _ = try HAPCredentials(string: "aabb:ccdd")
        }
        #expect(throws: HAPCredentialsError.self) {
            _ = try HAPCredentials(string: "aabb:ccdd:eeff")
        }
        #expect(throws: HAPCredentialsError.self) {
            _ = try HAPCredentials(string: "aabb:ccdd:eeff:0011:2233")
        }
        #expect(throws: HAPCredentialsError.self) {
            _ = try HAPCredentials(string: "")
        }
    }

    @Test func throwsOnOddLengthHexField() {
        #expect(throws: HAPCredentialsError.self) {
            _ = try HAPCredentials(string: "abc:1122:3344:5566")
        }
    }

    @Test func throwsOnInvalidHexDigit() {
        #expect(throws: HAPCredentialsError.self) {
            _ = try HAPCredentials(string: "zz11:1122:3344:5566")
        }
    }
}
