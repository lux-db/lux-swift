import Foundation
import Security

extension LuxConfigurationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidURL: "The Lux project URL is invalid."
        case .unsupportedScheme: "The Lux project URL must use HTTP or HTTPS."
        case .insecureRemoteURL: "Remote Lux projects must use HTTPS."
        case .userInfoNotAllowed: "The Lux project URL cannot contain a username or password."
        case .queryOrFragmentNotAllowed: "The Lux project URL cannot contain a query or fragment."
        }
    }
}

extension LuxSecurityError: LocalizedError {
    public var errorDescription: String? {
        "Secret Lux keys cannot be embedded in a client application. Use a publishable key."
    }
}

extension LuxEncodingError: LocalizedError {
    public var errorDescription: String? { "Lux could not encode the request." }
}

extension LuxError: LocalizedError {
    public var errorDescription: String? { message }
}

extension LuxAPIError: LocalizedError {
    public var errorDescription: String? { message }
}

extension LuxResponseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .nonHTTPResponse: "Lux received an invalid network response."
        case .decoding: "Lux could not decode the server response."
        }
    }
}

extension LuxSessionPersistenceError: LocalizedError {
    public var errorDescription: String? {
        "Lux could not safely persist the session and clear the incomplete Keychain state."
    }
}

extension LuxSessionStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            SecCopyErrorMessageString(status, nil) as String? ?? "Keychain failed with status \(status)."
        case .invalidData:
            "The stored Lux session is invalid."
        }
    }
}

extension LuxPushStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            SecCopyErrorMessageString(status, nil) as String? ?? "Keychain failed with status \(status)."
        case .invalidData:
            "The stored Lux push registration is invalid."
        }
    }
}
