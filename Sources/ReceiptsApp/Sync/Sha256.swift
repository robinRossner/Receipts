import CryptoKit
import Foundation

enum Sha256 {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Hash of a file read from disk (the archive checks the bytes it actually saved, not the ones it was handed).
    static func hex(ofFileAt url: URL) throws -> String {
        hex(try Data(contentsOf: url, options: .uncached))
    }
}
