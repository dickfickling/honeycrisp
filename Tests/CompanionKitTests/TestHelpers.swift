import Foundation

/// Decode a (whitespace-tolerant) hex string into `Data`, for compactly
/// porting the byte vectors from pyatv/nodeatv's test suites.
func hexData(_ hex: String) -> Data {
    let cleaned = hex.filter { !$0.isWhitespace }
    precondition(cleaned.count % 2 == 0, "odd-length hex string")
    var data = Data(capacity: cleaned.count / 2)
    var idx = cleaned.startIndex
    while idx < cleaned.endIndex {
        let next = cleaned.index(idx, offsetBy: 2)
        guard let byte = UInt8(cleaned[idx..<next], radix: 16) else {
            preconditionFailure("invalid hex byte in test vector")
        }
        data.append(byte)
        idx = next
    }
    return data
}
