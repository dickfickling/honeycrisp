import Foundation
import Testing
@testable import CompanionKit

/// Frame codec + incremental parser tests, porting the vectors/behaviors from
/// nodeatv `tests/protocols/companion/connection.test.ts` and pyatv's
/// `connection.py` framing loop.
struct CompanionFrameTests {
    @Test func frameTypeRawValues() {
        // Ported from connection.test.ts "has expected enum values".
        #expect(FrameType.unknown.rawValue == 0)
        #expect(FrameType.noOp.rawValue == 1)
        #expect(FrameType.psStart.rawValue == 3)
        #expect(FrameType.psNext.rawValue == 4)
        #expect(FrameType.pvStart.rawValue == 5)
        #expect(FrameType.pvNext.rawValue == 6)
        #expect(FrameType.uOPACK.rawValue == 7)
        #expect(FrameType.eOPACK.rawValue == 8)
        #expect(FrameType.pOPACK.rawValue == 9)
        #expect(FrameType.paReq.rawValue == 10)
        #expect(FrameType.paRsp.rawValue == 11)
        #expect(FrameType.sessionStartRequest.rawValue == 16)
        #expect(FrameType.sessionStartResponse.rawValue == 17)
        #expect(FrameType.sessionData.rawValue == 18)
        #expect(FrameType.familyIdentityRequest.rawValue == 32)
        #expect(FrameType.familyIdentityResponse.rawValue == 33)
        #expect(FrameType.familyIdentityUpdate.rawValue == 34)
    }

    @Test func headerEncodesTypeAndBigEndianLength() throws {
        // E_OPACK (8), payload length 256 -> 08 00 01 00
        let header = try CompanionFraming.header(typeByte: FrameType.eOPACK.rawValue, payloadLength: 256)
        #expect(header == hexData("08 00 01 00"))
    }

    @Test func headerDecodesCorrectly() {
        // 07 00 00 0a -> U_OPACK, length 10
        var parser = CompanionFrameParser()
        parser.append(hexData("07 00 00 0a") + Data(count: 10))
        let frame = parser.next()
        #expect(frame?.typeByte == FrameType.uOPACK.rawValue)
        #expect(frame?.payload.count == 10)
    }

    @Test func headerHandlesZeroLengthPayload() {
        var parser = CompanionFrameParser()
        parser.append(hexData("01 00 00 00")) // NoOp, empty
        let frame = parser.next()
        #expect(frame?.typeByte == FrameType.noOp.rawValue)
        #expect(frame?.payload.isEmpty == true)
        #expect(parser.next() == nil)
    }

    @Test func headerHandlesThreeByteLength() throws {
        let header = try CompanionFraming.header(
            typeByte: FrameType.eOPACK.rawValue, payloadLength: 0x0F_FFFF)
        #expect(header == hexData("08 0f ff ff"))
    }

    @Test func maxPayloadLengthIsThreeBytes() throws {
        let header = try CompanionFraming.header(
            typeByte: FrameType.eOPACK.rawValue, payloadLength: 0xFF_FFFF)
        #expect(header == hexData("08 ff ff ff"))
        #expect(throws: CompanionFrameError.payloadTooLarge(0x100_0000)) {
            _ = try CompanionFraming.header(
                typeByte: FrameType.eOPACK.rawValue, payloadLength: 0x100_0000)
        }
    }

    @Test func parserWaitsForCompleteHeader() {
        var parser = CompanionFrameParser()
        parser.append(hexData("08 00"))
        #expect(parser.next() == nil)
        parser.append(hexData("00 04") + Data("test".utf8))
        let frame = parser.next()
        #expect(frame?.payload == Data("test".utf8))
    }

    @Test func parserWaitsForCompletePayloadAcrossChunks() {
        var parser = CompanionFrameParser()
        parser.append(hexData("08 00 00 04")) // header only
        #expect(parser.next() == nil)
        parser.append(Data("te".utf8))
        #expect(parser.next() == nil)
        parser.append(Data("st".utf8))
        let frame = parser.next()
        #expect(frame?.header == hexData("08 00 00 04"))
        #expect(frame?.payload == Data("test".utf8))
        #expect(parser.next() == nil)
    }

    @Test func parserYieldsMultipleFramesFromOneBuffer() {
        var parser = CompanionFrameParser()
        let f1 = hexData("07 00 00 02") + Data([0xAA, 0xBB])
        let f2 = hexData("08 00 00 01") + Data([0xCC])
        parser.append(f1 + f2)
        let first = parser.next()
        let second = parser.next()
        #expect(first?.typeByte == FrameType.uOPACK.rawValue)
        #expect(first?.payload == Data([0xAA, 0xBB]))
        #expect(second?.typeByte == FrameType.eOPACK.rawValue)
        #expect(second?.payload == Data([0xCC]))
        #expect(parser.next() == nil)
    }

    @Test func parserRoundTripsLargePayload() throws {
        // > 64 KiB payload to exercise the multi-byte length field.
        let length = 70_000
        let payload = Data((0 ..< length).map { UInt8($0 & 0xFF) })
        let header = try CompanionFraming.header(
            typeByte: FrameType.eOPACK.rawValue, payloadLength: length)
        #expect(header == hexData("08 01 11 70")) // 70000 = 0x011170

        var parser = CompanionFrameParser()
        // Deliver in awkward chunks to also exercise reassembly.
        let wire = header + payload
        parser.append(wire.prefix(5))
        #expect(parser.next() == nil)
        parser.append(wire.dropFirst(5))
        let frame = parser.next()
        #expect(frame?.payload == payload)
    }
}
