import CryptoKit
import Foundation

enum Nonce {
    /// Lowercase hex of SHA-256(input), matching the engine's nonce check.
    static func sha256Hex(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
