import Foundation
import Testing
@testable import Lux

struct LuxClientTests {
    @Test func appleNonceUsesServerEndpoint() async throws {
        let transport = RecordingTransport { request, _ in
            let data = Data(#"{"nonce":"server-one-time-nonce"}"#.utf8)
            return (data, Self.response(url: request.url!, status: 200))
        }
        let client = try LuxClient(
            url: "https://example.com",
            publishableKey: "public-key",
            transport: transport
        )

        let nonce = try await client.appleSignInNonce()

        #expect(nonce == "server-one-time-nonce")
        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "https://example.com/auth/v1/signin/apple/nonce")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.httpBody == Data("{}".utf8))
    }

    @Test func appleSignInBuildsJSONRequestAndDecodesResponse() async throws {
        let transport = RecordingTransport { request, _ in
            let response = Self.response(url: request.url!, status: 200)
            return (Self.sessionData(accessToken: "access-1"), response)
        }
        let client = try LuxClient(
            url: "https://example.com/",
            publishableKey: "public-key",
            transport: transport
        )

        let session = try await client.signInWithApple(AppleSignInBody(
            idToken: "identity-token",
            nonce: "raw-nonce",
            user: .init(name: "Taylor Example")
        ))

        #expect(session.accessToken == "access-1")
        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "https://example.com/auth/v1/signin/apple")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "apikey") == "public-key")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["id_token"] as? String == "identity-token")
        #expect(json["nonce"] as? String == "raw-nonce")
        #expect((json["user"] as? [String: Any])?["name"] as? String == "Taylor Example")
    }

    @Test func refreshUsesGrantQueryAndRefreshTokenBody() async throws {
        let transport = RecordingTransport { request, _ in
            (Self.sessionData(accessToken: "new-access"), Self.response(url: request.url!, status: 200))
        }
        let client = try LuxClient(
            url: "https://example.com",
            publishableKey: "public-key",
            transport: transport
        )

        _ = try await client.refreshSession(refreshToken: "refresh-value")

        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "https://example.com/auth/v1/token?grant_type=refresh_token")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == ["refresh_token": "refresh-value"])
    }

    @Test func nonSuccessResponseThrowsTypedAPIError() async throws {
        let transport = RecordingTransport { request, _ in
            let data = Data(#"{"code":"invalid_grant","message":"Refresh token is invalid"}"#.utf8)
            return (data, Self.response(url: request.url!, status: 401))
        }
        let client = try LuxClient(
            url: "https://example.com",
            publishableKey: "public-key",
            transport: transport
        )

        do {
            _ = try await client.refreshSession(refreshToken: "invalid")
            Issue.record("Expected refresh to fail")
        } catch let error as LuxAPIError {
            #expect(error.statusCode == 401)
            #expect(error.code == "invalid_grant")
            #expect(error.message == "Refresh token is invalid")
        }
    }

    @Test func validatesProjectURLs() throws {
        let local = try LuxClient(url: "http://localhost:5890/", publishableKey: "public-key")
        #expect(local.baseURL.absoluteString == "http://localhost:5890")
        _ = try LuxClient(url: "http://127.0.0.1:5890", publishableKey: "public-key")
        _ = try LuxClient(url: "http://[::1]:5890", publishableKey: "public-key")

        for url in [
            "http://10.0.0.144:15890",
            "http://172.16.0.1:15890",
            "http://172.31.255.254:15890",
            "http://192.168.64.1:15890",
            "http://169.254.1.1:15890",
            "http://engine.local:15890",
            "http://lux-engine:15890",
            "http://[fd00::1]:15890",
            "http://[fe80::1]:15890",
        ] {
            _ = try LuxClient(
                url: url,
                publishableKey: "public-key",
                networkPolicy: .localDevelopment
            )
        }

        #expect(throws: LuxConfigurationError.insecureRemoteURL) {
            try LuxClient(url: "http://example.com", publishableKey: "public-key")
        }
        #expect(throws: LuxConfigurationError.insecureRemoteURL) {
            try LuxClient(url: "http://10.0.0.144:15890", publishableKey: "public-key")
        }
        #expect(throws: LuxConfigurationError.insecureRemoteURL) {
            try LuxClient(
                url: "http://8.8.8.8:15890",
                publishableKey: "public-key",
                networkPolicy: .localDevelopment
            )
        }
        #expect(throws: LuxConfigurationError.insecureRemoteURL) {
            try LuxClient(
                url: "http://172.32.0.1:15890",
                publishableKey: "public-key",
                networkPolicy: .localDevelopment
            )
        }
        for deceptiveHost in ["fc-example.com", "fd.example.com", "fe80.example.com"] {
            #expect(throws: LuxConfigurationError.insecureRemoteURL) {
                try LuxClient(
                    url: "http://\(deceptiveHost)",
                    publishableKey: "public-key",
                    networkPolicy: .localDevelopment
                )
            }
        }
        #expect(throws: LuxConfigurationError.userInfoNotAllowed) {
            try LuxClient(url: "https://user@example.com", publishableKey: "public-key")
        }
        #expect(throws: LuxConfigurationError.queryOrFragmentNotAllowed) {
            try LuxClient(url: "https://example.com/project?debug=true", publishableKey: "public-key")
        }
        #expect(throws: LuxConfigurationError.queryOrFragmentNotAllowed) {
            try LuxClient(url: "https://example.com/project#fragment", publishableKey: "public-key")
        }
        #expect(throws: LuxConfigurationError.unsupportedScheme) {
            try LuxClient(url: "ftp://example.com", publishableKey: "public-key")
        }
        #expect(throws: LuxConfigurationError.invalidURL) {
            try LuxClient(url: "not a url", publishableKey: "public-key")
        }
    }

    @Test func publicErrorsHaveUsefulLocalizedDescriptions() {
        #expect(LuxError(code: "NO_SESSION", message: "No authenticated session").localizedDescription == "No authenticated session")
        #expect(LuxAPIError(statusCode: 401, message: "Session expired").localizedDescription == "Session expired")
        #expect(LuxSecurityError.secretKeyNotAllowed.localizedDescription.contains("publishable key"))
        #expect(LuxConfigurationError.insecureRemoteURL.localizedDescription.contains("HTTPS"))
    }

    static func sessionData(accessToken: String, expiresIn: Int = 3600) -> Data {
        Data("""
        {
          "access_token": "\(accessToken)",
          "token_type": "bearer",
          "expires_in": \(expiresIn),
          "refresh_token": "refresh-1",
          "user": { "id": "user-1", "email": "user@example.com" }
        }
        """.utf8)
    }

    static func response(url: URL, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

actor RecordingTransport: LuxTransport {
    private(set) var requests: [URLRequest] = []
    private let handler: @Sendable (URLRequest, Int) async throws -> (Data, URLResponse)

    init(handler: @escaping @Sendable (URLRequest, Int) async throws -> (Data, URLResponse)) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return try await handler(request, requests.count)
    }
}
