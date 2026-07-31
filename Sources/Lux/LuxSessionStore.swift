import Foundation
import Security

public struct LuxStoredSession: Codable, Sendable, Equatable {
    public let session: LuxSession
    public let appleUserIdentifier: String?

    public init(session: LuxSession, appleUserIdentifier: String? = nil) {
        self.session = session
        self.appleUserIdentifier = appleUserIdentifier
    }
}

public protocol LuxSessionStore: Sendable {
    func load() throws -> LuxStoredSession?
    func save(_ storedSession: LuxStoredSession) throws
    func clear() throws
}

public struct KeychainLuxSessionStore: LuxSessionStore {
    private let service: String
    private let account: String

    public init(service: String = "com.lux.auth.session", account: String = "default") {
        self.service = service
        self.account = account
    }

    public func load() throws -> LuxStoredSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw LuxSessionStoreError.keychain(status)
        }

        do {
            return try JSONDecoder().decode(LuxStoredSession.self, from: data)
        } catch {
            throw LuxSessionStoreError.invalidData
        }
    }

    public func save(_ storedSession: LuxStoredSession) throws {
        let data = try JSONEncoder().encode(storedSession)
        let status = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if status == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData as String] = data
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw LuxSessionStoreError.keychain(addStatus)
            }
        } else if status != errSecSuccess {
            throw LuxSessionStoreError.keychain(status)
        }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LuxSessionStoreError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }
}

public enum LuxSessionStoreError: Error, Sendable, Equatable {
    case keychain(OSStatus)
    case invalidData
}
