import Foundation
import Testing
@testable import Lux

@MainActor
struct LuxIntegrationTests {
    /// Opt-in contract test against a real Lux engine. CI or local development
    /// supplies an isolated project URL and publishable key.
    @Test func anonymousAuthAndSelfPushRegistrationAgainstEngine() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard
            let url = environment["LUX_INTEGRATION_URL"],
            let key = environment["LUX_INTEGRATION_PUBLISHABLE_KEY"]
        else { return }

        let client = try LuxClient(url: url, publishableKey: key)
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
}
