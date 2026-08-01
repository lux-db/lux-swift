import Foundation
import Testing
@testable import Lux

@MainActor
struct LuxExpandedAuthTests {
    @Test func passwordSignInPersistsExpandedUserAndEmitsEvent() async throws {
        let transport = RecordingTransport { request, _ in
            let data = Data("""
            {
              "access_token":"access-password","token_type":"bearer","expires_in":3600,
              "refresh_token":"refresh-password",
              "user":{"id":"user-1","email":"person@example.com","phone":"+15551234",
                "user_metadata":{"name":"Taylor","onboarded":true}}
            }
            """.utf8)
            return (data, LuxClientTests.response(url: request.url!, status: 200))
        }
        let store = MemorySessionStore()
        let auth = LuxAuth(client: Self.client(transport), sessionStore: store)
        let stream = auth.events()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == .initialSession(nil))

        let session = try await auth.signInWithPassword(
            email: "person@example.com",
            password: "correct horse battery staple"
        )

        #expect(session.user.phone == "+15551234")
        #expect(session.user.userMetadata?["name"] == .string("Taylor"))
        #expect(session.expiresAt != nil)
        #expect(store.stored?.session == session)
        #expect(await iterator.next() == .signedIn(session))
        let request = try #require(await transport.requests.first)
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["grant_type"] == "password")
        #expect(json["email"] == "person@example.com")
    }

    @Test func signUpCanReturnUserAwaitingEmailConfirmation() async throws {
        let transport = RecordingTransport { request, _ in
            let data = Data(#"{"user":{"id":"pending","email":"pending@example.com"}}"#.utf8)
            return (data, LuxClientTests.response(url: request.url!, status: 200))
        }
        let store = MemorySessionStore()
        let auth = LuxAuth(client: Self.client(transport), sessionStore: store)

        let result = try await auth.signUp(
            email: "pending@example.com",
            password: "password123",
            metadata: ["plan": .string("pro")],
            emailRedirectTo: URL(string: "vigil://auth/callback")
        )

        #expect(result.session == nil)
        #expect(result.user.id == "pending")
        #expect(auth.session == nil)
        #expect(store.stored == nil)
        let request = try #require(await transport.requests.first)
        let json = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(json["email_redirect_to"] as? String == "vigil://auth/callback")
        #expect((json["data"] as? [String: String])?["plan"] == "pro")
    }

    @Test func anonymousOTPRecoveryAndUserUpdateUseExpectedContracts() async throws {
        let transport = RecordingTransport { request, index in
            switch index {
            case 1, 3:
                return (
                    LuxClientTests.sessionData(accessToken: index == 1 ? "anonymous" : "verified"),
                    LuxClientTests.response(url: request.url!, status: 200)
                )
            case 2:
                return (Data(#"{"ok":true}"#.utf8), LuxClientTests.response(url: request.url!, status: 200))
            case 4:
                let data = Data(#"{"user":{"id":"user-1","email":"new@example.com","user_metadata":{"name":"New"}}}"#.utf8)
                return (data, LuxClientTests.response(url: request.url!, status: 200))
            default:
                throw TestStoreError.saveFailed
            }
        }
        let auth = LuxAuth(client: Self.client(transport), sessionStore: MemorySessionStore())

        _ = try await auth.signInAnonymously()
        try await auth.resetPassword(
            for: "person@example.com",
            redirectTo: URL(string: "vigil://auth/recovery")
        )
        _ = try await auth.verifyOTP(tokenHash: "hash", type: .recovery)
        let user = try await auth.updateUser(
            email: "new@example.com",
            metadata: ["name": .string("New")]
        )

        #expect(user.email == "new@example.com")
        #expect(auth.user == user)
        let requests = await transport.requests
        #expect(requests.map { $0.url!.path } == [
            "/auth/v1/signin/anonymous",
            "/auth/v1/recover",
            "/auth/v1/verify",
            "/auth/v1/user",
        ])
        #expect(requests[3].value(forHTTPHeaderField: "Authorization") == "Bearer verified")
    }

    @Test func buildsCodeFlowAuthorizationURLAndExchangesCode() async throws {
        let transport = RecordingTransport { request, _ in
            (LuxClientTests.sessionData(accessToken: "oauth"), LuxClientTests.response(url: request.url!, status: 200))
        }
        let client = Self.client(transport)
        let url = try client.authorizationURL(
            provider: .github,
            redirectURL: URL(string: "vigil://auth/callback")!,
            codeChallenge: "challenge"
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query == [
            "provider": "github",
            "redirect_to": "vigil://auth/callback",
            "flow": "code",
            "code_challenge": "challenge",
            "code_challenge_method": "S256",
        ])

        let auth = LuxAuth(client: client, sessionStore: MemorySessionStore())
        _ = try await auth.exchangeCodeForSession(
            "one-time-code",
            codeVerifier: "verifier"
        )
        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "https://example.com/auth/v1/token?grant_type=authorization_code")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == [
            "grant_type": "authorization_code",
            "code": "one-time-code",
            "code_verifier": "verifier",
        ])
    }

    @Test(arguments: ["lux_sec_do-not-ship", "lux_sk_do-not-ship"])
    func mobileClientRejectsSecretKeys(_ key: String) {
        #expect(throws: LuxSecurityError.secretKeyNotAllowed) {
            try LuxClient(url: "https://example.com", publishableKey: key)
        }
    }

    private static func client(_ transport: any LuxTransport) -> LuxClient {
        try! LuxClient(url: "https://example.com", publishableKey: "lux_pub_public", transport: transport)
    }
}
