import Foundation

/// A Lux project client: the base URL of a project's API and its publishable key.
public struct LuxClient: Sendable {
    public let baseURL: URL
    public let publishableKey: String
    private let transport: any LuxTransport

    public init(
        url: String,
        publishableKey: String,
        transport: any LuxTransport = URLSessionLuxTransport()
    ) throws {
        var trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard
            let components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased(),
            !host.isEmpty,
            let base = components.url
        else {
            throw LuxConfigurationError.invalidURL
        }
        guard scheme == "https" || scheme == "http" else {
            throw LuxConfigurationError.unsupportedScheme
        }
        guard components.user == nil && components.password == nil else {
            throw LuxConfigurationError.userInfoNotAllowed
        }
        guard components.query == nil && components.fragment == nil else {
            throw LuxConfigurationError.queryOrFragmentNotAllowed
        }
        let normalizedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let localHost = normalizedHost == "localhost" || normalizedHost == "127.0.0.1" || normalizedHost == "::1"
        guard scheme == "https" || localHost else {
            throw LuxConfigurationError.insecureRemoteURL
        }
        self.baseURL = base
        self.publishableKey = publishableKey
        self.transport = transport
    }

    public init(url: String, publishableKey: String, session: URLSession) throws {
        try self.init(
            url: url,
            publishableKey: publishableKey,
            transport: URLSessionLuxTransport(session: session)
        )
    }

    func signInWithApple(_ body: AppleSignInBody) async throws -> LuxSession {
        try await postJSON(path: "/auth/v1/signin/apple", body: body)
    }

    func appleSignInNonce() async throws -> String {
        let response: AppleNonceResponse = try await postJSON(
            path: "/auth/v1/signin/apple/nonce",
            body: EmptyBody()
        )
        return response.nonce
    }

    func refreshSession(refreshToken: String) async throws -> LuxSession {
        try await postJSON(
            path: "/auth/v1/token",
            queryItems: [URLQueryItem(name: "grant_type", value: "refresh_token")],
            body: RefreshTokenBody(refreshToken: refreshToken)
        )
    }

    func logout(accessToken: String, refreshToken: String) async throws {
        try await postJSONWithoutResponse(
            path: "/auth/v1/logout",
            body: RefreshTokenBody(refreshToken: refreshToken),
            bearerToken: accessToken
        )
    }

    private func postJSON<Body: Encodable, Response: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Body
    ) async throws -> Response {
        var request = makeRequest(path: path, queryItems: queryItems)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let data = try await send(request)

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw LuxResponseError.decoding
        }
    }

    private func postJSONWithoutResponse<Body: Encodable>(
        path: String,
        body: Body,
        bearerToken: String? = nil
    ) async throws {
        var request = makeRequest(path: path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)
        _ = try await send(request)
    }

    private func makeRequest(path: String, queryItems: [URLQueryItem] = []) -> URLRequest {
        let url = baseURL.appending(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LuxResponseError.nonHTTPResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = try? JSONDecoder().decode(LuxErrorBody.self, from: data)
            throw LuxAPIError(
                statusCode: http.statusCode,
                code: body?.resolvedCode,
                message: body?.resolvedMessage ?? "Lux request failed with HTTP \(http.statusCode)"
            )
        }
        return data
    }
}

public enum LuxConfigurationError: Error, Sendable, Equatable {
    case invalidURL
    case unsupportedScheme
    case insecureRemoteURL
    case userInfoNotAllowed
    case queryOrFragmentNotAllowed
}

public struct LuxError: Error, Sendable, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct LuxAPIError: Error, Sendable, Equatable {
    public let statusCode: Int
    public let code: String?
    public let message: String

    public init(statusCode: Int, code: String? = nil, message: String) {
        self.statusCode = statusCode
        self.code = code
        self.message = message
    }

    var invalidatesRefreshToken: Bool {
        let code = (code ?? message)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
        return [
            "invalid_grant",
            "invalid_refresh_token",
            "refresh_token_already_used",
            "refresh_token_expired",
            "refresh_token_invalid",
            "refresh_token_not_found",
            "refresh_token_reuse_detected",
            "refresh_token_revoked",
            "user_banned",
            "user_deleted",
            "user_not_found",
        ].contains(code)
    }
}

public enum LuxResponseError: Error, Sendable, Equatable {
    case nonHTTPResponse
    case decoding
}

private struct LuxErrorBody: Decodable {
    let error: String?
    let errorDescription: String?
    let code: String?
    let message: String?

    var resolvedCode: String? {
        if let code { return code }
        guard let error, !error.contains(where: \.isWhitespace) else { return nil }
        return error
    }
    var resolvedMessage: String? { message ?? errorDescription ?? error }

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
        case code
        case message
    }
}

struct AppleSignInBody: Encodable {
    let idToken: String
    let nonce: String
    let user: User?

    struct User: Encodable {
        let name: String
    }

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case nonce
        case user
    }
}

private struct AppleNonceResponse: Decodable {
    let nonce: String
}

private struct EmptyBody: Encodable {}

private struct RefreshTokenBody: Encodable {
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

/// A Lux auth session. Timestamps are epoch seconds.
public struct LuxSession: Codable, Sendable, Equatable {
    public let accessToken: String
    public let tokenType: String
    public let expiresIn: Int
    public let refreshToken: String
    public let user: LuxUser
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
    public var isAnonymous: Bool?

    public init(id: String, email: String? = nil, isAnonymous: Bool? = nil) {
        self.id = id
        self.email = email
        self.isAnonymous = isAnonymous
    }

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case isAnonymous = "is_anonymous"
    }
}
