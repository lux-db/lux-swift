import Foundation

struct SignUpBody: Encodable {
    let email: String
    let password: String
    let data: [String: LuxJSONValue]?
    let emailRedirectTo: String?
    enum CodingKeys: String, CodingKey {
        case email, password, data
        case emailRedirectTo = "email_redirect_to"
    }
}

struct SignUpResponse: Decodable {
    let session: LuxSession?
    let user: LuxUser

    init(from decoder: Decoder) throws {
        if let session = try? LuxSession(from: decoder) {
            self.session = session
            self.user = session.user
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.session = nil
        self.user = try container.decode(LuxUser.self, forKey: .user)
    }

    private enum CodingKeys: String, CodingKey { case user }
}

struct PasswordSignInBody: Encodable {
    let grantType = "password"
    let email: String
    let password: String
    enum CodingKeys: String, CodingKey {
        case grantType = "grant_type"
        case email, password
    }
}

struct AuthorizationCodeBody: Encodable {
    let grantType = "authorization_code"
    let code: String
    let codeVerifier: String?
    enum CodingKeys: String, CodingKey {
        case grantType = "grant_type"
        case code
        case codeVerifier = "code_verifier"
    }
}

struct PasswordRecoveryBody: Encodable {
    let email: String
    let redirectTo: String?
    enum CodingKeys: String, CodingKey {
        case email
        case redirectTo = "redirect_to"
    }
}

struct VerifyOTPBody: Encodable {
    let tokenHash: String
    let type: String
    enum CodingKeys: String, CodingKey {
        case tokenHash = "token_hash"
        case type
    }
}

struct UpdateUserBody: Encodable {
    let email: String?
    let password: String?
    let userMetadata: [String: LuxJSONValue]?
    enum CodingKeys: String, CodingKey {
        case email, password
        case userMetadata = "user_metadata"
    }
}

struct UserResponse: Decodable { let user: LuxUser }
