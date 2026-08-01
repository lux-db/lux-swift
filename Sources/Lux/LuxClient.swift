import Foundation

/// Low-level HTTP client shared by Lux's client-safe namespaces.
///
/// Applications normally create a ``LuxProject``. `LuxClient` stays public for
/// dependency injection and for existing 1.0 applications that construct
/// ``LuxAuth`` directly.
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
        guard !publishableKey.hasPrefix("lux_sk_") else {
            throw LuxSecurityError.secretKeyNotAllowed
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

    // MARK: 1.0 auth transport compatibility

    func signInWithApple(_ body: AppleSignInBody) async throws -> LuxSession {
        try await request(.post, path: "/auth/v1/signin/apple", body: body)
    }

    func appleSignInNonce() async throws -> String {
        let response: AppleNonceResponse = try await request(
            .post,
            path: "/auth/v1/signin/apple/nonce",
            body: EmptyBody()
        )
        return response.nonce
    }

    func refreshSession(refreshToken: String) async throws -> LuxSession {
        try await request(
            .post,
            path: "/auth/v1/token",
            queryItems: [URLQueryItem(name: "grant_type", value: "refresh_token")],
            body: RefreshTokenBody(refreshToken: refreshToken)
        )
    }

    func logout(accessToken: String, refreshToken: String) async throws {
        try await requestWithoutResponse(
            .post,
            path: "/auth/v1/logout",
            body: RefreshTokenBody(refreshToken: refreshToken),
            bearerToken: accessToken
        )
    }

    func request<Response: Decodable>(
        _ method: LuxHTTPMethod,
        path: String,
        queryItems: [URLQueryItem] = [],
        bearerToken: String? = nil,
        as _: Response.Type = Response.self
    ) async throws -> Response {
        try await requestData(
            method,
            path: path,
            queryItems: queryItems,
            bearerToken: bearerToken,
            body: nil,
            contentType: nil
        )
    }

    func request<Body: Encodable, Response: Decodable>(
        _ method: LuxHTTPMethod,
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Body,
        bearerToken: String? = nil,
        as _: Response.Type = Response.self
    ) async throws -> Response {
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(body)
        } catch {
            throw LuxEncodingError.encoding
        }
        return try await requestData(
            method,
            path: path,
            queryItems: queryItems,
            bearerToken: bearerToken,
            body: encoded,
            contentType: "application/json"
        )
    }

    func requestWithoutResponse<Body: Encodable>(
        _ method: LuxHTTPMethod,
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Body,
        bearerToken: String? = nil
    ) async throws {
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(body)
        } catch {
            throw LuxEncodingError.encoding
        }
        _ = try await send(makeRequest(
            method,
            path: path,
            queryItems: queryItems,
            bearerToken: bearerToken,
            body: encoded,
            contentType: "application/json"
        ))
    }

    func requestWithoutResponse(
        _ method: LuxHTTPMethod,
        path: String,
        queryItems: [URLQueryItem] = [],
        bearerToken: String? = nil
    ) async throws {
        _ = try await send(makeRequest(
            method,
            path: path,
            queryItems: queryItems,
            bearerToken: bearerToken,
            body: nil,
            contentType: nil
        ))
    }

    func authorizationURL(
        provider: LuxOAuthProvider,
        redirectURL: URL,
        flow: LuxOAuthFlow = .code,
        codeChallenge: String? = nil
    ) throws -> URL {
        var components = URLComponents(
            url: baseURL.appending(path: "auth/v1/authorize"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "provider", value: provider.rawValue),
            URLQueryItem(name: "redirect_to", value: redirectURL.absoluteString),
            URLQueryItem(name: "flow", value: flow.rawValue),
        ]
        if let codeChallenge {
            components.queryItems?.append(URLQueryItem(name: "code_challenge", value: codeChallenge))
            components.queryItems?.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        }
        guard let url = components.url else { throw LuxConfigurationError.invalidURL }
        return url
    }

    private func requestData<Response: Decodable>(
        _ method: LuxHTTPMethod,
        path: String,
        queryItems: [URLQueryItem],
        bearerToken: String?,
        body: Data?,
        contentType: String?
    ) async throws -> Response {
        let data = try await send(makeRequest(
            method,
            path: path,
            queryItems: queryItems,
            bearerToken: bearerToken,
            body: body,
            contentType: contentType
        ))
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw LuxResponseError.decoding
        }
    }

    private func makeRequest(
        _ method: LuxHTTPMethod,
        path: String,
        queryItems: [URLQueryItem],
        bearerToken: String?,
        body: Data?,
        contentType: String?
    ) -> URLRequest {
        let relativePath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url = baseURL.appending(path: relativePath)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        var request = URLRequest(url: components.url!)
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("lux-swift/1.1", forHTTPHeaderField: "X-Lux-Client")
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body
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

enum LuxHTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}

public enum LuxConfigurationError: Error, Sendable, Equatable {
    case invalidURL
    case unsupportedScheme
    case insecureRemoteURL
    case userInfoNotAllowed
    case queryOrFragmentNotAllowed
}

public enum LuxSecurityError: Error, Sendable, Equatable {
    case secretKeyNotAllowed
}

public enum LuxEncodingError: Error, Sendable, Equatable {
    case encoding
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
