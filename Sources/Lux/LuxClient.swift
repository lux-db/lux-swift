import Foundation

/// A Lux project client: the base URL of a project's data API plus its
/// publishable key. This seed covers the auth surface (Sign in with Apple);
/// tables, live, and storage land on top of the same transport.
public struct LuxClient: Sendable {
    public let baseURL: URL
    public let publishableKey: String
    private let session: URLSession

    public init(url: String, publishableKey: String, session: URLSession = .shared) {
        // Trailing slashes are stripped so path joins are predictable.
        let trimmed = url.hasSuffix("/") ? String(url.dropLast()) : url
        guard let base = URL(string: trimmed) else {
            preconditionFailure("LuxClient: invalid url \(url)")
        }
        self.baseURL = base
        self.publishableKey = publishableKey
        self.session = session
    }

    /// POST JSON to an auth path (e.g. `/auth/v1/signin/apple`). Sends the
    /// publishable key as `apikey`; unauthenticated calls need no bearer token.
    func postJSON<Body: Encodable, Response: Decodable>(
        path: String,
        body: Body,
        as _: Response.Type
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LuxError(code: "LUX_NO_RESPONSE", message: "no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(LuxErrorBody.self, from: data))?.error
                ?? "Lux request failed with HTTP \(http.statusCode)"
            throw LuxError(code: "LUX_REQUEST_ERROR", message: message)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

public struct LuxError: Error, Sendable, Equatable {
    public let code: String
    public let message: String
}

struct LuxErrorBody: Decodable {
    let error: String
}

/// A Lux auth session. Field names match the wire (`token_type` is always
/// `"bearer"`; timestamps are epoch seconds).
public struct LuxSession: Codable, Sendable, Equatable {
    public let accessToken: String
    public let tokenType: String
    public let expiresIn: Int
    public let refreshToken: String
    public let user: LuxUser
    public var expiresAt: Int?

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

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case isAnonymous = "is_anonymous"
    }
}
