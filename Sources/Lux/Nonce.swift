import CryptoKit
import Foundation
import Security

enum Nonce {
    /// Lowercase hex of SHA-256(input), matching the engine's nonce check.
    static func sha256Hex(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct PKCEPair: Sendable, Equatable {
    let verifier: String
    let challenge: String
}

enum PKCE {
    static func generate() throws -> PKCEPair {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw LuxError(
                code: "PKCE_RANDOM_FAILED",
                message: "Could not create secure OAuth verifier"
            )
        }
        let verifier = base64URL(Data(bytes))
        return PKCEPair(verifier: verifier, challenge: challenge(for: verifier))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
