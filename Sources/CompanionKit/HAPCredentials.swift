import Foundation

/// Errors produced while parsing a `HAPCredentials` string representation.
public enum HAPCredentialsError: Error, Equatable, Sendable {
    /// The string was not four colon-separated hex fields, or one of the
    /// fields was not valid hex, mirroring pyatv's
    /// `InvalidCredentialsError("invalid credentials: ...")`.
    case invalidFormat(String)
}

/// HAP long-term keys and identifiers, as exchanged via the Companion/HAP
/// pairing flow.
///
/// Mirrors the wire-relevant subset of pyatv's `HapCredentials`
/// (`pyatv.auth.hap_pairing`): the four raw byte fields and the
/// colon-separated hex string representation (`ltpk:ltsk:atv_id:client_id`).
/// pyatv's `AuthenticationType` classification and the 2-field "legacy"
/// string form are out of scope here; later tasks that need pairing-state
/// semantics can layer that on top of this codec.
public struct HAPCredentials: Equatable, Sendable {
    public var ltpk: Data
    public var ltsk: Data
    public var atvId: Data
    public var clientId: Data

    public init(ltpk: Data = Data(), ltsk: Data = Data(), atvId: Data = Data(), clientId: Data = Data()) {
        self.ltpk = ltpk
        self.ltsk = ltsk
        self.atvId = atvId
        self.clientId = clientId
    }

    /// Parse the `ltpk:ltsk:atv_id:client_id` hex string representation
    /// produced by pyatv's `HapCredentials.__str__`.
    ///
    /// - Throws: `HAPCredentialsError.invalidFormat` if `string` does not
    ///   have exactly four colon-separated fields, or if any field is not
    ///   valid hex (odd length or a non-hex-digit character), matching
    ///   pyatv's `parse_credentials` (`binascii.Error` there becomes
    ///   `InvalidCredentialsError`).
    public init(string: String) throws {
        let parts = string.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            throw HAPCredentialsError.invalidFormat(string)
        }
        self.ltpk = try HAPCredentials.data(fromHex: parts[0], original: string)
        self.ltsk = try HAPCredentials.data(fromHex: parts[1], original: string)
        self.atvId = try HAPCredentials.data(fromHex: parts[2], original: string)
        self.clientId = try HAPCredentials.data(fromHex: parts[3], original: string)
    }

    /// Re-encode as the colon-separated lowercase hex string pyatv's
    /// `HapCredentials.__str__` produces.
    public var stringValue: String {
        [ltpk, ltsk, atvId, clientId].map(HAPCredentials.hex(from:)).joined(separator: ":")
    }

    private static func data(fromHex hex: Substring, original: String) throws -> Data {
        guard hex.count % 2 == 0 else {
            throw HAPCredentialsError.invalidFormat(original)
        }
        var data = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else {
                throw HAPCredentialsError.invalidFormat(original)
            }
            data.append(byte)
            idx = next
        }
        return data
    }

    private static func hex(from data: Data) -> String {
        var s = ""
        s.reserveCapacity(data.count * 2)
        for byte in data {
            s += String(format: "%02x", byte)
        }
        return s
    }
}
