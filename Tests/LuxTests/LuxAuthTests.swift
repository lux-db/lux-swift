import Foundation
import Testing
@testable import Lux

@MainActor
struct LuxAuthTests {
    @Test func restoresSessionThroughInjectedStore() async throws {
        let stored = LuxStoredSession(
            session: Self.makeSession(accessToken: "persisted", expiresAt: 4_000),
            appleUserIdentifier: "apple-user"
        )
        let store = MemorySessionStore(stored)
        let auth = LuxAuth(
            client: Self.makeClient(transport: RecordingTransport { request, _ in
                (Data(), LuxClientTests.response(url: request.url!, status: 200))
            }),
            sessionStore: store,
            credentialStateProvider: FixedCredentialStateProvider(state: .authorized)
        )

        let restored = try await auth.restoreSession()

        #expect(restored == stored.session)
        #expect(auth.isAuthenticated)
        #expect(store.loadCount == 1)
    }

    @Test func missingRestoreClearsExistingInMemorySession() async throws {
        let store = MemorySessionStore(LuxStoredSession(session: Self.makeSession()))
        let auth = LuxAuth(
            client: Self.makeClient(transport: RecordingTransport { request, _ in
                (Data(), LuxClientTests.response(url: request.url!, status: 200))
            }),
            sessionStore: store
        )
        _ = try await auth.restoreSession()
        try store.clear()

        #expect(try await auth.restoreSession() == nil)
        #expect(auth.session == nil)
    }

    @Test func revokedAppleCredentialClearsPersistedSession() async throws {
        let store = MemorySessionStore(LuxStoredSession(
            session: Self.makeSession(),
            appleUserIdentifier: "revoked-user"
        ))
        let auth = LuxAuth(
            client: Self.makeClient(transport: RecordingTransport { request, _ in
                (Data(), LuxClientTests.response(url: request.url!, status: 200))
            }),
            sessionStore: store,
            credentialStateProvider: FixedCredentialStateProvider(state: .revoked)
        )

        #expect(try await auth.restoreSession() == nil)
        #expect(store.stored == nil)
        #expect(store.clearCount == 1)
    }

    @Test func concurrentRefreshIsSerializedAndPersistsExpiry() async throws {
        let transport = RecordingTransport { request, _ in
            try await Task.sleep(for: .milliseconds(50))
            return (
                LuxClientTests.sessionData(accessToken: "refreshed", expiresIn: 120),
                LuxClientTests.response(url: request.url!, status: 200)
            )
        }
        let store = MemorySessionStore(LuxStoredSession(session: Self.makeSession(expiresAt: 900)))
        let auth = LuxAuth(
            client: Self.makeClient(transport: transport),
            sessionStore: store,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        _ = try await auth.restoreSession()

        async let first = auth.refreshSession()
        async let second = auth.refreshSession()
        let (firstSession, secondSession) = try await (first, second)
        let sessions = [firstSession, secondSession]

        #expect(sessions.allSatisfy { $0.accessToken == "refreshed" })
        #expect(sessions.allSatisfy { $0.expiresAt == 1_120 })
        #expect(await transport.requests.count == 1)
        #expect(auth.session?.expiresAt == 1_120)
        #expect(store.stored?.session.expiresAt == 1_120)
    }

    @Test func invalidRefreshClearsLocalAndPersistedSession() async throws {
        let transport = RecordingTransport { request, _ in
            let data = Data(#"{"error":"refresh token expired"}"#.utf8)
            return (data, LuxClientTests.response(url: request.url!, status: 401))
        }
        let store = MemorySessionStore(LuxStoredSession(session: Self.makeSession(expiresAt: 900)))
        let auth = LuxAuth(client: Self.makeClient(transport: transport), sessionStore: store)
        _ = try await auth.restoreSession()

        do {
            _ = try await auth.refreshSession()
            Issue.record("Expected refresh to fail")
        } catch is LuxAPIError {
            #expect(auth.session == nil)
            #expect(store.stored == nil)
        }
    }

    @Test func genericUnauthorizedRefreshDoesNotDiscardSession() async throws {
        let transport = RecordingTransport { request, _ in
            let data = Data(#"{"code":"authorization_failed","message":"Request denied"}"#.utf8)
            return (data, LuxClientTests.response(url: request.url!, status: 401))
        }
        let original = LuxStoredSession(session: Self.makeSession(expiresAt: 900))
        let store = MemorySessionStore(original)
        let auth = LuxAuth(client: Self.makeClient(transport: transport), sessionStore: store)
        _ = try await auth.restoreSession()

        do {
            _ = try await auth.refreshSession()
            Issue.record("Expected refresh to fail")
        } catch is LuxAPIError {
            #expect(auth.session == original.session)
            #expect(store.stored == original)
        }
    }

    @Test(arguments: ["user not found", "user deleted", "user banned"])
    func terminalUserRefreshErrorsClearSession(message: String) async throws {
        let transport = RecordingTransport { request, _ in
            let data = Data("{\"error\":\"\(message)\"}".utf8)
            return (data, LuxClientTests.response(url: request.url!, status: 401))
        }
        let store = MemorySessionStore(LuxStoredSession(session: Self.makeSession()))
        let auth = LuxAuth(client: Self.makeClient(transport: transport), sessionStore: store)
        _ = try await auth.restoreSession()

        do {
            _ = try await auth.refreshSession()
            Issue.record("Expected refresh to fail")
        } catch is LuxAPIError {
            #expect(auth.session == nil)
            #expect(store.stored == nil)
        }
    }

    @Test func rotatedRefreshSaveFailureClearsObsoleteSession() async throws {
        let transport = RecordingTransport { request, _ in
            (
                LuxClientTests.sessionData(accessToken: "rotated-access"),
                LuxClientTests.response(url: request.url!, status: 200)
            )
        }
        let store = MemorySessionStore(
            LuxStoredSession(session: Self.makeSession(expiresAt: 900)),
            saveFailure: TestStoreError.saveFailed
        )
        let auth = LuxAuth(client: Self.makeClient(transport: transport), sessionStore: store)
        _ = try await auth.restoreSession()

        do {
            _ = try await auth.refreshSession()
            Issue.record("Expected persistence to fail")
        } catch TestStoreError.saveFailed {
            #expect(auth.session == nil)
            #expect(store.stored == nil)
            #expect(store.clearCount == 1)
        }
    }

    @Test func logoutInvalidatesCancellationResistantRefreshCompletion() async throws {
        let gate = SuspensionGate()
        let transport = RecordingTransport { request, _ in
            if request.url?.path == "/auth/v1/token" {
                await gate.suspend()
                return (
                    LuxClientTests.sessionData(accessToken: "stale-refresh"),
                    LuxClientTests.response(url: request.url!, status: 200)
                )
            }
            return (Data(), LuxClientTests.response(url: request.url!, status: 204))
        }
        let store = MemorySessionStore(LuxStoredSession(session: Self.makeSession(expiresAt: 900)))
        let auth = LuxAuth(client: Self.makeClient(transport: transport), sessionStore: store)
        _ = try await auth.restoreSession()

        let refresh = Task { try await auth.refreshSession() }
        await gate.waitUntilStarted()
        try await auth.signOut()
        await gate.release()

        do {
            _ = try await refresh.value
            Issue.record("Expected stale refresh to be cancelled")
        } catch is CancellationError {
            #expect(auth.session == nil)
            #expect(store.stored == nil)
            #expect(await transport.requests.count == 2)
        }
    }

    @Test func logoutInvalidatesCancellationResistantRestoreCompletion() async throws {
        let gate = SuspensionGate()
        let store = MemorySessionStore(LuxStoredSession(
            session: Self.makeSession(),
            appleUserIdentifier: "apple-user"
        ))
        let auth = LuxAuth(
            client: Self.makeClient(transport: RecordingTransport { request, _ in
                (Data(), LuxClientTests.response(url: request.url!, status: 204))
            }),
            sessionStore: store,
            credentialStateProvider: GatedCredentialStateProvider(gate: gate)
        )

        let restore = Task { try await auth.restoreSession() }
        await gate.waitUntilStarted()
        try await auth.signOut()
        await gate.release()

        do {
            _ = try await restore.value
            Issue.record("Expected stale restore to be cancelled")
        } catch is CancellationError {
            #expect(auth.session == nil)
            #expect(store.stored == nil)
        }
    }

    @Test func logoutInvalidatesCancellationResistantUserUpdate() async throws {
        let gate = SuspensionGate()
        let transport = RecordingTransport { request, _ in
            if request.url?.path == "/auth/v1/user" {
                await gate.suspend()
                return (
                    Data(#"{"user":{"id":"user-1","email":"stale@example.com"}}"#.utf8),
                    LuxClientTests.response(url: request.url!, status: 200)
                )
            }
            return (Data(), LuxClientTests.response(url: request.url!, status: 204))
        }
        let store = MemorySessionStore(LuxStoredSession(
            session: Self.makeSession(expiresAt: Int.max)
        ))
        let auth = LuxAuth(client: Self.makeClient(transport: transport), sessionStore: store)
        _ = try await auth.restoreSession()

        let update = Task { try await auth.updateUser(email: "stale@example.com") }
        await gate.waitUntilStarted()
        try await auth.signOut()
        await gate.release()

        do {
            _ = try await update.value
            Issue.record("Expected stale user update to be cancelled")
        } catch is CancellationError {
            #expect(auth.session == nil)
            #expect(store.stored == nil)
        }
    }

    @Test func logoutPostsBearerThenClearsLocalSession() async throws {
        let transport = RecordingTransport { request, _ in
            (Data(), LuxClientTests.response(url: request.url!, status: 204))
        }
        let store = MemorySessionStore(LuxStoredSession(session: Self.makeSession(accessToken: "logout-token")))
        let auth = LuxAuth(client: Self.makeClient(transport: transport), sessionStore: store)
        _ = try await auth.restoreSession()

        try await auth.signOut()

        let request = try #require(await transport.requests.first)
        #expect(request.url?.path == "/auth/v1/logout")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer logout-token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == ["refresh_token": "refresh-1"])
        #expect(auth.session == nil)
        #expect(store.stored == nil)
    }

    @Test func logoutStoreFailureStillClearsMemoryAndCallsServer() async throws {
        let transport = RecordingTransport { request, _ in
            (Data(), LuxClientTests.response(url: request.url!, status: 204))
        }
        let original = LuxStoredSession(session: Self.makeSession())
        let store = MemorySessionStore(original, clearFailure: TestStoreError.clearFailed)
        let auth = LuxAuth(client: Self.makeClient(transport: transport), sessionStore: store)
        _ = try await auth.restoreSession()

        do {
            try await auth.signOut()
            Issue.record("Expected store clear to fail")
        } catch TestStoreError.clearFailed {
            #expect(auth.session == nil)
            #expect(store.stored == original)
            #expect(await transport.requests.count == 1)
        }
    }

    @Test func logoutFailureStillClearsLocalSession() async throws {
        let transport = RecordingTransport { request, _ in
            (Data(), LuxClientTests.response(url: request.url!, status: 500))
        }
        let store = MemorySessionStore(LuxStoredSession(session: Self.makeSession()))
        let auth = LuxAuth(client: Self.makeClient(transport: transport), sessionStore: store)
        _ = try await auth.restoreSession()

        do {
            try await auth.signOut()
            Issue.record("Expected logout to report the server failure")
        } catch is LuxAPIError {
            #expect(auth.session == nil)
            #expect(store.stored == nil)
        }
    }

    @Test func logoutRejectsOverlappingSignInDuringDependentCleanup() async throws {
        let gate = SuspensionGate()
        let transport = RecordingTransport { request, _ in
            if request.url?.path == "/auth/v1/signin/anonymous" {
                return (
                    LuxClientTests.sessionData(accessToken: "unexpected-sign-in"),
                    LuxClientTests.response(url: request.url!, status: 200)
                )
            }
            return (Data(), LuxClientTests.response(url: request.url!, status: 204))
        }
        let store = MemorySessionStore(LuxStoredSession(session: Self.makeSession()))
        let auth = LuxAuth(client: Self.makeClient(transport: transport), sessionStore: store)
        _ = try await auth.restoreSession()
        _ = auth.addPreSignOutHandler { _ in await gate.suspend() }

        let logout = Task { try await auth.signOut() }
        await gate.waitUntilStarted()
        #expect(auth.isSigningOut)
        await #expect(throws: CancellationError.self) {
            try await auth.signInAnonymously()
        }
        await gate.release()
        try await logout.value

        #expect(!auth.isSigningOut)
        #expect(!auth.isAuthenticated)
        #expect(store.stored == nil)
        #expect(await transport.requests.map(\.url?.path) == ["/auth/v1/logout"])
    }

    @Test func logoutInvalidatesCancellationResistantGetUser() async throws {
        let gate = SuspensionGate()
        let transport = RecordingTransport { request, _ in
            if request.url?.path == "/auth/v1/user" {
                await gate.suspend()
                return (
                    Data(#"{"user":{"id":"user-1","email":"stale@example.test"}}"#.utf8),
                    LuxClientTests.response(url: request.url!, status: 200)
                )
            }
            return (Data(), LuxClientTests.response(url: request.url!, status: 204))
        }
        let auth = LuxAuth(
            client: Self.makeClient(transport: transport),
            sessionStore: MemorySessionStore(LuxStoredSession(session: Self.makeSession(
                expiresAt: Int(Date().timeIntervalSince1970) + 3_600
            )))
        )
        _ = try await auth.restoreSession()

        let getUser = Task { try await auth.getUser() }
        await gate.waitUntilStarted()
        let logout = Task { try await auth.signOut() }
        await Task.yield()
        await gate.release()

        await #expect(throws: CancellationError.self) { try await getUser.value }
        try await logout.value
        #expect(!auth.isAuthenticated)
    }

    private static func makeClient(transport: any LuxTransport) -> LuxClient {
        try! LuxClient(url: "https://example.com", publishableKey: "public-key", transport: transport)
    }

    private static func makeSession(
        accessToken: String = "access-1",
        expiresAt: Int? = 3_600
    ) -> LuxSession {
        LuxSession(
            accessToken: accessToken,
            expiresIn: 3_600,
            refreshToken: "refresh-1",
            user: LuxUser(id: "user-1"),
            expiresAt: expiresAt
        )
    }
}

final class MemorySessionStore: LuxSessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: LuxStoredSession?
    private(set) var loadCount = 0
    private(set) var clearCount = 0
    private let saveFailure: Error?
    private let clearFailure: Error?

    init(
        _ value: LuxStoredSession? = nil,
        saveFailure: Error? = nil,
        clearFailure: Error? = nil
    ) {
        self.value = value
        self.saveFailure = saveFailure
        self.clearFailure = clearFailure
    }

    var stored: LuxStoredSession? {
        lock.withLock { value }
    }

    func load() throws -> LuxStoredSession? {
        lock.withLock {
            loadCount += 1
            return value
        }
    }

    func save(_ storedSession: LuxStoredSession) throws {
        try lock.withLock {
            if let saveFailure { throw saveFailure }
            value = storedSession
        }
    }

    func clear() throws {
        try lock.withLock {
            clearCount += 1
            if let clearFailure { throw clearFailure }
            value = nil
        }
    }
}

enum TestStoreError: Error {
    case saveFailed
    case clearFailed
}

struct FixedCredentialStateProvider: LuxAppleCredentialStateProviding {
    let state: LuxAppleCredentialState

    func credentialState(forUserID userID: String) async throws -> LuxAppleCredentialState {
        state
    }
}

struct GatedCredentialStateProvider: LuxAppleCredentialStateProviding {
    let gate: SuspensionGate

    func credentialState(forUserID userID: String) async throws -> LuxAppleCredentialState {
        await gate.suspend()
        return .authorized
    }
}

actor SuspensionGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var blocked: CheckedContinuation<Void, Never>?

    func suspend() async {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { blocked = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        blocked?.resume()
        blocked = nil
    }
}
