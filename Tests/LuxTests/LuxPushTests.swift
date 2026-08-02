import Foundation
import Testing
@preconcurrency import UserNotifications
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
        #expect(requests.map { $0.url!.path } == ["/push/devices", "/auth/v1/logout"])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer access" })
        let deleteBody = try #require(requests[0].httpBody)
        let deleteJSON = try #require(JSONSerialization.jsonObject(with: deleteBody) as? [String: String])
        #expect(deleteJSON["token"] == "token")
        #expect(push.registration?.token == "token")
        #expect(push.registration?.deviceID == nil)
        #expect(push.registration?.userID == nil)
    }

    @Test func tokenRotationRegistersNewTokenThenRemovesSupersededToken() async throws {
        let transport = RecordingTransport { request, index in
            if index == 1 {
                return (
                    Data(#"{"id":"new-device"}"#.utf8),
                    LuxClientTests.response(url: request.url!, status: 200)
                )
            }
            return (
                Data(#"{"deleted":true}"#.utf8),
                LuxClientTests.response(url: request.url!, status: 200)
            )
        }
        let client = Self.client(transport)
        let auth = LuxAuth(
            client: client,
            sessionStore: MemorySessionStore(LuxStoredSession(session: Self.session()))
        )
        _ = try await auth.restoreSession()
        let store = MemoryPushStore(LuxStoredPushRegistration(
            token: "old-token",
            environment: .sandbox,
            deviceID: "old-device",
            userID: "user-1"
        ))
        let push = LuxPush(
            client: client,
            auth: auth,
            store: store,
            system: FixedPushSystem(),
            environmentProvider: FixedEnvironmentProvider(environment: .sandbox)
        )

        try await push.register(token: "new-token", environment: .sandbox)

        let requests = await transport.requests
        #expect(requests.map { $0.httpMethod } == ["POST", "DELETE"])
        #expect(requests.map { $0.url!.path } == ["/push/devices", "/push/devices"])
        let register = try #require(
            JSONSerialization.jsonObject(with: requests[0].httpBody!) as? [String: String]
        )
        let cleanup = try #require(
            JSONSerialization.jsonObject(with: requests[1].httpBody!) as? [String: String]
        )
        #expect(register["token"] == "new-token")
        #expect(cleanup["token"] == "old-token")
        #expect(push.registration?.token == "new-token")
        #expect(push.registration?.deviceID == "new-device")
        #expect(push.registration?.pendingRemovalTokens == nil)
    }

    @Test func failedRotationCleanupIsPersistedAndRetried() async throws {
        let transport = RecordingTransport { request, index in
            if request.httpMethod == "POST" {
                return (
                    Data(#"{"id":"new-device"}"#.utf8),
                    LuxClientTests.response(url: request.url!, status: 200)
                )
            }
            return (
                Data(index == 2 ? #"{"error":"temporary"}"#.utf8 : #"{"deleted":true}"#.utf8),
                LuxClientTests.response(url: request.url!, status: index == 2 ? 503 : 200)
            )
        }
        let client = Self.client(transport)
        let auth = LuxAuth(
            client: client,
            sessionStore: MemorySessionStore(LuxStoredSession(session: Self.session()))
        )
        _ = try await auth.restoreSession()
        let store = MemoryPushStore(LuxStoredPushRegistration(
            token: "old-token",
            environment: .sandbox,
            deviceID: "old-device",
            userID: "user-1"
        ))
        let push = LuxPush(
            client: client,
            auth: auth,
            store: store,
            system: FixedPushSystem(),
            environmentProvider: FixedEnvironmentProvider(environment: .sandbox),
            automaticallySynchronizesAuthEvents: false
        )

        do {
            try await push.register(token: "new-token", environment: .sandbox)
            Issue.record("Expected superseded-token cleanup to fail")
        } catch is LuxAPIError {
            #expect(store.stored?.token == "new-token")
            #expect(store.stored?.deviceID == nil)
            #expect(store.stored?.pendingRemovalTokens == ["old-token"])
        }

        try await push.synchronize()
        #expect(store.stored?.deviceID == "new-device")
        #expect(store.stored?.pendingRemovalTokens == nil)
        let requests = await transport.requests
        #expect(requests.map { $0.httpMethod } == ["POST", "DELETE", "POST", "DELETE"])
    }

    @Test func storedRegistrationDecodesBeforePendingCleanupFieldExisted() throws {
        let stored = try JSONDecoder().decode(
            LuxStoredPushRegistration.self,
            from: Data(#"{"token":"legacy","environment":"sandbox","appID":"default"}"#.utf8)
        )
        #expect(stored.token == "legacy")
        #expect(stored.pendingRemovalTokens == nil)
    }

    @Test func disableCleansPendingTokensBeforeForgettingLocalRegistration() async throws {
        let transport = RecordingTransport { request, _ in
            (
                Data(#"{"deleted":true}"#.utf8),
                LuxClientTests.response(url: request.url!, status: 200)
            )
        }
        let client = Self.client(transport)
        let auth = LuxAuth(
            client: client,
            sessionStore: MemorySessionStore(LuxStoredSession(session: Self.session()))
        )
        _ = try await auth.restoreSession()
        let store = MemoryPushStore(LuxStoredPushRegistration(
            token: "current-token",
            environment: .sandbox,
            appID: "default",
            deviceID: nil,
            userID: nil,
            pendingRemovalTokens: ["old-token"]
        ))
        let push = LuxPush(
            client: client,
            auth: auth,
            store: store,
            system: FixedPushSystem(),
            environmentProvider: FixedEnvironmentProvider(environment: .sandbox),
            automaticallySynchronizesAuthEvents: false
        )

        try await push.disable()

        let requests = await transport.requests
        let deletedTokens = try requests.map { request in
            let body = try #require(request.httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
            return json["token"]
        }
        #expect(deletedTokens == ["current-token", "old-token"])
        #expect(store.stored == nil)
        #expect(push.registration == nil)
    }

    @Test func signOutWaitsForInflightRegistrationThenDeletesByToken() async throws {
        let gate = SuspensionGate()
        let transport = RecordingTransport { request, index in
            switch index {
            case 1:
                await gate.suspend()
                return (
                    Data(#"{"id":"raced-device"}"#.utf8),
                    LuxClientTests.response(url: request.url!, status: 200)
                )
            case 2:
                return (
                    Data(#"{"deleted":true}"#.utf8),
                    LuxClientTests.response(url: request.url!, status: 200)
                )
            default:
                return (Data(), LuxClientTests.response(url: request.url!, status: 204))
            }
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
            store: MemoryPushStore(LuxStoredPushRegistration(
                token: "raced-token",
                environment: .sandbox
            )),
            system: FixedPushSystem(),
            environmentProvider: FixedEnvironmentProvider(environment: .sandbox),
            automaticallySynchronizesAuthEvents: false
        )
        let synchronization = Task { try await push.synchronize() }
        await gate.waitUntilStarted()

        let signOut = Task { try await auth.signOut() }
        await Task.yield()
        #expect(!(await transport.requests.map { $0.url!.path }.contains("/auth/v1/logout")))
        await gate.release()
        try await signOut.value
        _ = try? await synchronization.value

        let requests = await transport.requests
        #expect(requests.map { $0.url!.path } == [
            "/push/devices",
            "/push/devices",
            "/auth/v1/logout",
        ])
        let cleanup = try #require(
            JSONSerialization.jsonObject(with: requests[1].httpBody!) as? [String: String]
        )
        #expect(cleanup["token"] == "raced-token")
        #expect(push.registration?.token == "raced-token")
        #expect(push.registration?.deviceID == nil)
    }

    @Test func rotatedTokenCannotBeOverwrittenByStaleRegistrationResponse() async throws {
        let gate = SuspensionGate()
        let transport = RecordingTransport { request, _ in
            let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
            if request.httpMethod == "POST", body?.contains(#""token":"old-token""#) == true {
                await gate.suspend()
                return (
                    Data(#"{"id":"old-device"}"#.utf8),
                    LuxClientTests.response(url: request.url!, status: 200)
                )
            }
            if request.httpMethod == "DELETE" {
                return (
                    Data(#"{"deleted":true}"#.utf8),
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

    @Test func richImageHelperAttachesValidatedHTTPSImage() async throws {
        let url = URL(string: "https://images.example.com/valid.png")!
        ImageURLProtocol.install(
            url: url,
            status: 200,
            contentType: "image/png",
            data: Self.pixelPNG
        )
        let session = Self.imageSession()
        defer { session.invalidateAndCancel() }
        let content = UNMutableNotificationContent()
        content.userInfo = ["image_url": url.absoluteString]

        let enriched = await LuxPushAttachment.enrich(
            content,
            session: session,
            maximumBytes: 1_024
        )

        #expect(enriched.attachments.count == 1)
        #expect(ImageURLProtocol.requestCount(for: url) == 1)
    }

    @Test func richImageHelperRejectsInsecureNonImageAndOversizedContent() async {
        let session = Self.imageSession()
        defer { session.invalidateAndCancel() }

        let insecureURL = URL(string: "http://images.example.com/insecure.png")!
        ImageURLProtocol.install(
            url: insecureURL,
            status: 200,
            contentType: "image/png",
            data: Self.pixelPNG
        )
        let insecure = UNMutableNotificationContent()
        insecure.userInfo = ["image_url": insecureURL.absoluteString]
        #expect((await LuxPushAttachment.enrich(insecure, session: session)).attachments.isEmpty)
        #expect(ImageURLProtocol.requestCount(for: insecureURL) == 0)

        let textURL = URL(string: "https://images.example.com/not-image.png")!
        ImageURLProtocol.install(
            url: textURL,
            status: 200,
            contentType: "text/plain",
            data: Data("not an image".utf8)
        )
        let text = UNMutableNotificationContent()
        text.userInfo = ["image_url": textURL.absoluteString]
        #expect((await LuxPushAttachment.enrich(text, session: session)).attachments.isEmpty)

        let largeURL = URL(string: "https://images.example.com/large.png")!
        ImageURLProtocol.install(
            url: largeURL,
            status: 200,
            contentType: "image/png",
            data: Self.pixelPNG
        )
        let large = UNMutableNotificationContent()
        large.userInfo = ["image_url": largeURL.absoluteString]
        #expect((await LuxPushAttachment.enrich(
            large,
            session: session,
            maximumBytes: 8
        )).attachments.isEmpty)
    }

    private static func client(_ transport: any LuxTransport) -> LuxClient {
        try! LuxClient(url: "https://example.com", publishableKey: "lux_pub_public", transport: transport)
    }

    private static func imageSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static let pixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZQmcAAAAASUVORK5CYII="
    )!

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

final class ImageURLProtocol: URLProtocol, @unchecked Sendable {
    private struct Stub: Sendable {
        let status: Int
        let contentType: String
        let data: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [URL: Stub] = [:]
    nonisolated(unsafe) private static var requestCounts: [URL: Int] = [:]

    static func install(url: URL, status: Int, contentType: String, data: Data) {
        lock.withLock {
            stubs[url] = Stub(status: status, contentType: contentType, data: data)
            requestCounts[url] = 0
        }
    }

    static func requestCount(for url: URL) -> Int {
        lock.withLock { requestCounts[url, default: 0] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let stub = Self.lock.withLock { () -> Stub? in
            Self.requestCounts[url, default: 0] += 1
            return Self.stubs[url]
        }
        guard let stub else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": stub.contentType,
                "Content-Length": String(stub.data.count),
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
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
