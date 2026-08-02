import Foundation
import Testing
@testable import Lux

@MainActor
struct LuxIntegrationTests {
    @Test func passwordSessionLifecycleAgainstEngine() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard
            let url = environment["LUX_INTEGRATION_URL"],
            let key = environment["LUX_INTEGRATION_PUBLISHABLE_KEY"]
        else { return }

        let client = try Self.client(url: url, key: key, environment: environment)
        let auth = LuxAuth(client: client, sessionStore: MemorySessionStore())
        let identity = UUID().uuidString.lowercased()
        let email = "swift-\(identity)@example.test"
        let password = "lux-integration-\(identity)"

        let signup = try await auth.signUp(
            email: email,
            password: password,
            metadata: ["source": .string("lux-swift-integration")]
        )
        #expect(signup.session != nil)
        #expect(signup.user.email == email)

        try await auth.signOut()
        #expect(!auth.isAuthenticated)

        let passwordSession = try await auth.signInWithPassword(email: email, password: password)
        #expect(passwordSession.user.email == email)
        #expect(try await auth.getUser().id == passwordSession.user.id)

        let updated = try await auth.updateUser(metadata: ["verified": .bool(true)])
        #expect(updated.userMetadata?["verified"] == .bool(true))

        let refreshed = try await auth.refreshSession()
        #expect(refreshed.user.id == passwordSession.user.id)
        #expect(refreshed.refreshToken != passwordSession.refreshToken)

        try await auth.signOut()
        #expect(!auth.isAuthenticated)
        await #expect(throws: LuxError.self) { try await auth.accessToken() }
    }

    /// Opt-in contract test against a real Lux engine. CI or local development
    /// supplies an isolated project URL and publishable key.
    @Test func anonymousAuthAndSelfPushRegistrationAgainstEngine() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard
            let url = environment["LUX_INTEGRATION_URL"],
            let key = environment["LUX_INTEGRATION_PUBLISHABLE_KEY"]
        else { return }

        let client = try Self.client(url: url, key: key, environment: environment)
        let auth = LuxAuth(client: client, sessionStore: MemorySessionStore())
        let push = LuxPush(
            client: client,
            auth: auth,
            store: MemoryPushStore(),
            system: FixedPushSystem(),
            environmentProvider: FixedEnvironmentProvider(environment: .sandbox)
        )

        let session = try await auth.signInAnonymously()
        #expect(session.user.isAnonymous == true)

        let prefix = "swift-integration-\(UUID().uuidString.lowercased())"
        try await push.register(token: "\(prefix)-old", environment: .sandbox)
        let supersededID = try #require(push.registration?.deviceID)
        try await push.register(token: "\(prefix)-current", environment: .sandbox)
        let registeredID = try #require(push.registration?.deviceID)
        let devices = try await push.devices()
        #expect(devices.contains { $0.id == registeredID })
        #expect(!devices.contains { $0.id == supersededID })

        try await push.unregister()
        #expect(push.registration?.deviceID == nil)
        try await auth.signOut()
        #expect(auth.session == nil)
    }

    private static func client(
        url: String,
        key: String,
        environment: [String: String]
    ) throws -> LuxClient {
        let policy: LuxNetworkPolicy = environment["LUX_INTEGRATION_LOCAL_DEVELOPMENT"] == "true"
            ? .localDevelopment
            : .secure
        return try LuxClient(url: url, publishableKey: key, networkPolicy: policy)
    }
}
