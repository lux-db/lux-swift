import CryptoKit
import Foundation

enum Nonce {
    /// A random URL-safe nonce. The raw value is sent to Lux; its SHA-256 is
    /// handed to Apple, which echoes the hash in the identity token's `nonce`.
    static func random(length: Int = 32) -> String {
        let charset = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-._")
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return String(bytes.map { charset[Int($0) % charset.count] })
    }

    /// Lowercase hex of SHA-256(input), matching the engine's nonce check.
    static func sha256Hex(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
