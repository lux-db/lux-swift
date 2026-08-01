import Foundation

public enum LuxOAuthProvider: String, Codable, Sendable, CaseIterable {
    case apple
    case google
    case github
}

public enum LuxOAuthFlow: String, Codable, Sendable {
    case code
    case implicit
}

public enum LuxOTPType: String, Codable, Sendable {
    case signup
    case email
    case emailChange = "email_change"
    case recovery
}

public enum LuxAuthEvent: Sendable, Equatable {
    case initialSession(LuxSession?)
    case signedIn(LuxSession)
    case tokenRefreshed(LuxSession)
    case userUpdated(LuxUser)
    case signedOut
}

public struct LuxAuthResult: Sendable, Equatable {
    public let session: LuxSession?
    public let user: LuxUser

    public init(session: LuxSession?, user: LuxUser) {
        self.session = session
        self.user = user
    }
}

public struct LuxSession: Codable, Sendable, Equatable {
    public let accessToken: String
    public let tokenType: String
    public let expiresIn: Int
    public let refreshToken: String
    public var user: LuxUser
    public var expiresAt: Int?

    public init(
        accessToken: String,
        tokenType: String = "bearer",
        expiresIn: Int,
        refreshToken: String,
        user: LuxUser,
        expiresAt: Int? = nil
    ) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.expiresIn = expiresIn
        self.refreshToken = refreshToken
        self.user = user
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case user
        case expiresAt = "expires_at"
    }
}

public struct LuxUser: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var email: String?
    public var phone: String?
    public var emailConfirmedAt: Int?
    public var phoneConfirmedAt: Int?
    public var lastSignInAt: Int?
    public var createdAt: Int?
    public var updatedAt: Int?
    public var userMetadata: [String: LuxJSONValue]?
    public var appMetadata: [String: LuxJSONValue]?
    public var isAnonymous: Bool?

    public init(
        id: String,
        email: String? = nil,
        isAnonymous: Bool? = nil
    ) {
        self.id = id
        self.email = email
        self.isAnonymous = isAnonymous
    }

    public init(
        id: String,
        email: String? = nil,
        phone: String?,
        userMetadata: [String: LuxJSONValue]? = nil,
        appMetadata: [String: LuxJSONValue]? = nil,
        isAnonymous: Bool? = nil
    ) {
        self.id = id
        self.email = email
        self.phone = phone
        self.userMetadata = userMetadata
        self.appMetadata = appMetadata
        self.isAnonymous = isAnonymous
    }

    enum CodingKeys: String, CodingKey {
        case id, email, phone
        case emailConfirmedAt = "email_confirmed_at"
        case phoneConfirmedAt = "phone_confirmed_at"
        case lastSignInAt = "last_sign_in_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case userMetadata = "user_metadata"
        case appMetadata = "app_metadata"
        case isAnonymous = "is_anonymous"
    }
}

public enum LuxJSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: LuxJSONValue])
    case array([LuxJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: LuxJSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([LuxJSONValue].self) { self = .array(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct AppleSignInBody: Encodable {
    let idToken: String
    let nonce: String
    let user: User?

    struct User: Encodable { let name: String }

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case nonce, user
    }
}

struct AppleNonceResponse: Decodable { let nonce: String }
struct EmptyBody: Encodable {}
struct RefreshTokenBody: Encodable {
    let refreshToken: String
    enum CodingKeys: String, CodingKey { case refreshToken = "refresh_token" }
}
