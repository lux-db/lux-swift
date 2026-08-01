import Foundation
import Security

public struct LuxStoredPushRegistration: Codable, Sendable, Equatable {
    public let token: String
    public let environment: LuxAPNSEnvironment
    public let appID: String
    public let deviceID: String?
    public let userID: String?

    public init(
        token: String,
        environment: LuxAPNSEnvironment = .unspecified,
        appID: String = "default",
        deviceID: String? = nil,
        userID: String? = nil
    ) {
        self.token = token
        self.environment = environment
        self.appID = appID
        self.deviceID = deviceID
        self.userID = userID
    }
}

public protocol LuxPushRegistrationStore: Sendable {
    func load() throws -> LuxStoredPushRegistration?
    func save(_ registration: LuxStoredPushRegistration) throws
    func clear() throws
}

public struct KeychainLuxPushRegistrationStore: LuxPushRegistrationStore {
    private let service: String
    private let account: String

    public init(service: String = "com.lux.push.registration", account: String = "default") {
        self.service = service
        self.account = account
    }

    public func load() throws -> LuxStoredPushRegistration? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw LuxPushStoreError.keychain(status)
        }
        do { return try JSONDecoder().decode(LuxStoredPushRegistration.self, from: data) }
        catch { throw LuxPushStoreError.invalidData }
    }

    public func save(_ registration: LuxStoredPushRegistration) throws {
        let data = try JSONEncoder().encode(registration)
        let status = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData as String] = data
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw LuxPushStoreError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw LuxPushStoreError.keychain(status)
        }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LuxPushStoreError.keychain(status)
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

public enum LuxPushStoreError: Error, Sendable, Equatable {
    case keychain(OSStatus)
    case invalidData
}
