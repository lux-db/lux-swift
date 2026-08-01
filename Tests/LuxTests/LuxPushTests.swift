import Foundation
import Testing
@testable import Lux

@MainActor
struct LuxPushTests {
    @Test func tokenStaysPendingWithoutSessionAndRegistersWithoutSubjectIDAfterLogin() async throws {
        let transport = RecordingTransport { request, index in
            if index == 1 {
                return (
                    LuxClientTests.sessionData(accessToken: "signed-in"),
                    LuxClientTests.response(url: request.url!, status: 200)
                )
            }
            return (
                Data(#"{"id":"device-1"}"#.utf8),
                LuxClientTests.response(url: request.url!, status: 200)
            )
        }
        let client = Self.client(transport)
        let auth = LuxAuth(client: client, sessionStore: MemorySessionStore())
        let store = MemoryPushStore()
        let push = LuxPush(
            client: client,
            auth: auth,
            store: store,
            system: FixedPushSystem(),
            environmentProvider: FixedEnvironmentProvider(environment: .sandbox)
        )

        try await push.register(token: "aabbcc", environment: .sandbox)
        #expect(push.registration?.deviceID == nil)
        #expect(await transport.requests.isEmpty)

        _ = try await auth.signInAnonymously()
        try await Self.waitUntil { push.registration?.deviceID == "device-1" }

        let requests = await transport.requests
        #expect(requests.count == 2)
        let registrationRequest = requests[1]
        #expect(registrationRequest.url?.path == "/push/devices")
        #expect(registrationRequest.value(forHTTPHeaderField: "Authorization") == "Bearer signed-in")
        let body = try #require(registrationRequest.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["token"] == "aabbcc")
        #expect(json["environment"] == "sandbox")
        #expect(json["subject_id"] == nil)
        #expect(store.stored?.userID == "user-1")
    }

    @Test func dataTokenIsHexEncodedAndUsesEntitlementEnvironment() async throws {
        let transport = RecordingTransport { request, _ in
            (
                Data(#"{"id":"device-hex"}"#.utf8),
                LuxClientTests.response(url: request.url!, status: 200)
            )
        }
        let client = Self.client(transport)
        let auth = LuxAuth(
            client: client,
            sessionStore: MemorySessionStore(LuxStoredSession(session: Self.session()))
        )
        _ = try await auth.restoreSession()
        let push = LuxPush(
            client: client,
            auth: auth,
            store: MemoryPushStore(),
            system: FixedPushSystem(),
            environmentProvider: FixedEnvironmentProvider(environment: .production)
        )

        try await push.register(deviceToken: Data([0x00, 0x0f, 0xa0, 0xff]))

        let request = try #require(await transport.requests.first)
        let json = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String])
        #expect(json["token"] == "000fa0ff")
        #expect(json["environment"] == "production")
    }

    @Test func signOutDeletesDeviceBeforeRevokingSessionAndLeavesTokenPending() async throws {
        let transport = RecordingTransport { request, index in
            if index == 1 {
                return (
                    Data(#"{"deleted":true}"#.utf8),
                    LuxClientTests.response(url: request.url!, status: 200)
                )
            }
            return (Data(), LuxClientTests.response(url: request.url!, status: 204))
        }
        let client = Self.client(transport)
        let auth = LuxAuth(
            client: client,
            sessionStore: MemorySessionStore(LuxStoredSession(session: Self.session()))
        )
        _ = try await auth.restoreSession()
        let store = MemoryPushStore(LuxStoredPushRegistration(
            token: "token",
            environment: .production,
            deviceID: "device-1",
            userID: "user-1"
        ))
        let push = LuxPush(
            client: client,
            auth: auth,
            store: store,
            system: FixedPushSystem(),
            environmentProvider: FixedEnvironmentProvider(environment: .production)
        )

        try await auth.signOut()

        let requests = await transport.requests
        #expect(requests.map { $0.url!.path } == ["/push/devices/device-1", "/auth/v1/logout"])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer access" })
        #expect(push.registration?.token == "token")
        #expect(push.registration?.deviceID == nil)
        #expect(push.registration?.userID == nil)
    }

    @Test func rotatedTokenCannotBeOverwrittenByStaleRegistrationResponse() async throws {
        let gate = SuspensionGate()
        let transport = RecordingTransport { request, _ in
            let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
            if body?.contains(#""token":"old-token""#) == true {
                await gate.suspend()
                return (
                    Data(#"{"id":"old-device"}"#.utf8),
                    LuxClientTests.response(url: request.url!, status: 200)
                )
            }
            return (
                Data(#"{"id":"new-device"}"#.utf8),
                LuxClientTests.response(url: request.url!, status: 200)
            )
        }
        let client = Self.client(transport)
        let auth = LuxAuth(
            client: client,
            sessionStore: MemorySessionStore(LuxStoredSession(session: Self.session()))
        )
        _ = try await auth.restoreSession()
        let push = LuxPush(
            client: client,
            auth: auth,
            store: MemoryPushStore(),
            system: FixedPushSystem(),
            environmentProvider: FixedEnvironmentProvider(environment: .sandbox)
        )

        let stale = Task {
            try await push.register(token: "old-token", environment: .sandbox)
        }
        await gate.waitUntilStarted()
        try await push.register(token: "new-token", environment: .sandbox)
        await gate.release()

        do {
            try await stale.value
            Issue.record("Expected stale registration to be cancelled")
        } catch is CancellationError {
            #expect(push.registration?.token == "new-token")
            #expect(push.registration?.deviceID == "new-device")
            #expect(push.registration?.userID == "user-1")
        }
    }

    @Test func requestsPermissionAndStartsSystemRegistration() async throws {
        let system = FixedPushSystem(status: .authorized, grant: true)
        let client = Self.client(RecordingTransport { request, _ in
            (Data(), LuxClientTests.response(url: request.url!, status: 204))
        })
        let auth = LuxAuth(client: client, sessionStore: MemorySessionStore())
        let push = LuxPush(
            client: client,
            auth: auth,
            store: MemoryPushStore(),
            system: system,
            environmentProvider: FixedEnvironmentProvider(environment: .sandbox)
        )

        let status = try await push.requestAuthorization()

        #expect(status == .authorized)
        #expect(system.requestCount == 1)
        #expect(system.registrationCount == 1)
    }

    @Test func decodesLuxPayloadWithoutLeakingReservedEnvelope() {
        let payload = LuxPushPayload(userInfo: [
            "aps": [
                "alert": [
                    "title": "Hello",
                    "subtitle": "Team",
                    "body": "World",
                    "title-loc-key": "MESSAGE_TITLE",
                    "title-loc-args": ["Alice"],
                ],
                "badge": 3,
                "category": "MESSAGE",
                "thread-id": "room-1",
                "sound": ["critical": 1, "name": "alarm.caf", "volume": 0.7],
                "interruption-level": "time-sensitive",
                "relevance-score": 0.9,
                "target-content-id": "message-1",
                "content-available": 1,
                "mutable-content": 1,
            ],
            "image_url": "https://example.com/image.jpg",
            "conversation_id": "abc",
            "silent": false,
            "count": 4,
        ])

        #expect(payload.alert == LuxPushAlert(
            title: "Hello",
            subtitle: "Team",
            body: "World",
            titleLocalizationKey: "MESSAGE_TITLE",
            titleLocalizationArguments: ["Alice"]
        ))
        #expect(payload.badge == 3)
        #expect(payload.threadID == "room-1")
        #expect(payload.alert.titleLocalizationKey == "MESSAGE_TITLE")
        #expect(payload.alert.titleLocalizationArguments == ["Alice"])
        #expect(payload.sound == .critical(name: "alarm.caf", volume: 0.7))
        #expect(payload.interruptionLevel == .timeSensitive)
        #expect(payload.relevanceScore == 0.9)
        #expect(payload.targetContentID == "message-1")
        #expect(payload.contentAvailable)
        #expect(payload.mutableContent)
        #expect(payload.imageURL?.absoluteString == "https://example.com/image.jpg")
        #expect(payload.data == [
            "conversation_id": .string("abc"),
            "silent": .bool(false),
            "count": .number(4),
        ])
    }

    private static func client(_ transport: any LuxTransport) -> LuxClient {
        try! LuxClient(url: "https://example.com", publishableKey: "lux_pk_public", transport: transport)
    }

    private static func session() -> LuxSession {
        LuxSession(
            accessToken: "access",
            expiresIn: 3_600,
            refreshToken: "refresh",
            user: LuxUser(id: "user-1"),
            expiresAt: Int(Date().timeIntervalSince1970) + 3_600
        )
    }

    private static func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now >= deadline {
                Issue.record("Timed out waiting for push synchronization")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

final class MemoryPushStore: LuxPushRegistrationStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: LuxStoredPushRegistration?

    init(_ value: LuxStoredPushRegistration? = nil) { self.value = value }
    var stored: LuxStoredPushRegistration? { lock.withLock { value } }
    func load() throws -> LuxStoredPushRegistration? { stored }
    func save(_ registration: LuxStoredPushRegistration) throws { lock.withLock { value = registration } }
    func clear() throws { lock.withLock { value = nil } }
}

@MainActor
final class FixedPushSystem: LuxPushSystemProviding {
    var status: LuxPushAuthorizationStatus
    let grant: Bool
    private(set) var requestCount = 0
    private(set) var registrationCount = 0

    init(status: LuxPushAuthorizationStatus = .notDetermined, grant: Bool = false) {
        self.status = status
        self.grant = grant
    }

    func authorizationStatus() async -> LuxPushAuthorizationStatus { status }
    func requestAuthorization(options: LuxPushAuthorizationOptions) async throws -> Bool {
        requestCount += 1
        return grant
    }
    func registerForRemoteNotifications() { registrationCount += 1 }
}

struct FixedEnvironmentProvider: LuxAPNSEnvironmentProviding {
    let environmentValue: LuxAPNSEnvironment
    init(environment: LuxAPNSEnvironment) { self.environmentValue = environment }
    func environment() -> LuxAPNSEnvironment { environmentValue }
}
