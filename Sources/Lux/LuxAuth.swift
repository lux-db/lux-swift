import AuthenticationServices
import Foundation
import Observation

public enum LuxAppleCredentialState: Sendable, Equatable {
    case authorized
    case revoked
    case notFound
    case transferred
}

public protocol LuxAppleCredentialStateProviding: Sendable {
    func credentialState(forUserID userID: String) async throws -> LuxAppleCredentialState
}

public struct SystemAppleCredentialStateProvider: LuxAppleCredentialStateProviding {
    public init() {}

    public func credentialState(forUserID userID: String) async throws -> LuxAppleCredentialState {
        try await withCheckedThrowingContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { state, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                switch state {
                case .authorized: continuation.resume(returning: .authorized)
                case .revoked: continuation.resume(returning: .revoked)
                case .transferred: continuation.resume(returning: .transferred)
                case .notFound: continuation.resume(returning: .notFound)
                @unknown default: continuation.resume(returning: .notFound)
                }
            }
        }
    }
}

/// Observable, durable Lux authentication state for SwiftUI applications.
@MainActor
@Observable
public final class LuxAuth {
    public private(set) var session: LuxSession?
    public private(set) var isRestoring = false
    public private(set) var isSigningOut = false
    public var user: LuxUser? { session?.user }
    public var isAuthenticated: Bool { session != nil }

    private let client: LuxClient
    private let sessionStore: any LuxSessionStore
    private let credentialStateProvider: any LuxAppleCredentialStateProviding
    private let presentationAnchorProvider: () -> ASPresentationAnchor?
    private let now: @Sendable () -> Date
    private var appleCoordinator: AppleSignInCoordinator?
    private var webCoordinator: OAuthWebCoordinator?
    private var appleUserIdentifier: String?
    private var refreshTask: Task<LuxSession, Error>?
    private var lifecycleGeneration: UInt64 = 0
    private var eventContinuations: [UUID: AsyncStream<LuxAuthEvent>.Continuation] = [:]
    private var preSignOutHandlers: [UUID: @MainActor (LuxSession) async throws -> Void] = [:]

    public convenience init(
        client: LuxClient,
        presentationAnchor: @escaping () -> ASPresentationAnchor? = { nil }
    ) {
        self.init(
            client: client,
            sessionStore: KeychainLuxSessionStore(account: client.baseURL.absoluteString),
            presentationAnchor: presentationAnchor
        )
    }

    public init(
        client: LuxClient,
        sessionStore: any LuxSessionStore,
        credentialStateProvider: any LuxAppleCredentialStateProviding = SystemAppleCredentialStateProvider(),
        presentationAnchor: @escaping () -> ASPresentationAnchor? = { nil },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = client
        self.sessionStore = sessionStore
        self.credentialStateProvider = credentialStateProvider
        self.presentationAnchorProvider = presentationAnchor
        self.now = now
    }

    /// Auth lifecycle events. Each subscriber immediately receives the current
    /// session as `initialSession` and then receives changes until cancelled.
    public func events() -> AsyncStream<LuxAuthEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            eventContinuations[id] = continuation
            continuation.yield(.initialSession(session))
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.eventContinuations.removeValue(forKey: id) }
            }
        }
    }

    /// Restore the Keychain session and verify native Apple authorization when
    /// the session originated from Sign in with Apple.
    @discardableResult
    public func restoreSession() async throws -> LuxSession? {
        let generation = try beginLifecycleOperation()
        isRestoring = true
        defer { if lifecycleGeneration == generation { isRestoring = false } }
        try checkLifecycle(generation)
        guard let stored = try sessionStore.load() else {
            clearInMemorySession()
            emit(.initialSession(nil))
            return nil
        }

        if let appleUserID = stored.appleUserIdentifier {
            let state = try await credentialStateProvider.credentialState(forUserID: appleUserID)
            try checkLifecycle(generation)
            guard state == .authorized else {
                try clearLocalSession()
                emit(.signedOut)
                return nil
            }
        }

        try checkLifecycle(generation)
        session = stored.session
        appleUserIdentifier = stored.appleUserIdentifier
        emit(.initialSession(stored.session))
        return session
    }

    /// Create an email/password account. Projects requiring email confirmation
    /// return a user with a nil session until the verification link is consumed.
    @discardableResult
    public func signUp(
        email: String,
        password: String,
        metadata: [String: LuxJSONValue]? = nil,
        emailRedirectTo: URL? = nil
    ) async throws -> LuxAuthResult {
        let generation = try beginLifecycleOperation()
        let response: SignUpResponse = try await client.request(
            .post,
            path: "/auth/v1/signup",
            body: SignUpBody(
                email: email,
                password: password,
                data: metadata,
                emailRedirectTo: emailRedirectTo?.absoluteString
            )
        )
        try checkLifecycle(generation)
        guard let newSession = response.session else {
            return LuxAuthResult(session: nil, user: response.user)
        }
        let session = normalized(newSession)
        try persistAndSetSession(session, appleUserIdentifier: nil, event: .signedIn(session))
        return LuxAuthResult(session: session, user: session.user)
    }

    @discardableResult
    public func signInWithPassword(email: String, password: String) async throws -> LuxSession {
        let generation = try beginLifecycleOperation()
        let session: LuxSession = try await client.request(
            .post,
            path: "/auth/v1/token",
            body: PasswordSignInBody(email: email, password: password)
        )
        try checkLifecycle(generation)
        let normalized = normalized(session)
        try persistAndSetSession(normalized, appleUserIdentifier: nil, event: .signedIn(normalized))
        return normalized
    }

    @discardableResult
    public func signInAnonymously() async throws -> LuxSession {
        let generation = try beginLifecycleOperation()
        let session: LuxSession = try await client.request(
            .post,
            path: "/auth/v1/signin/anonymous",
            body: EmptyBody()
        )
        try checkLifecycle(generation)
        let normalized = normalized(session)
        try persistAndSetSession(normalized, appleUserIdentifier: nil, event: .signedIn(normalized))
        return normalized
    }

    /// Present the native Sign in with Apple sheet and exchange its identity token.
    @discardableResult
    public func signInWithApple() async throws -> LuxSession {
        let generation = try beginLifecycleOperation()
        try checkLifecycle(generation)
        let nonce: AppleNonceResponse = try await client.request(
            .post,
            path: "/auth/v1/signin/apple/nonce",
            body: EmptyBody()
        )
        try checkLifecycle(generation)

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Nonce.sha256Hex(nonce.nonce)

        let coordinator = AppleSignInCoordinator(presentationAnchorProvider: presentationAnchorProvider)
        appleCoordinator = coordinator
        defer { if lifecycleGeneration == generation { appleCoordinator = nil } }
        let credential = try await coordinator.perform(request: request)
        try checkLifecycle(generation)

        guard
            let tokenData = credential.identityToken,
            let idToken = String(data: tokenData, encoding: .utf8)
        else {
            throw LuxError(code: "APPLE_NO_IDENTITY_TOKEN", message: "Apple returned no identity token")
        }
        let name = credential.fullName.flatMap { components -> String? in
            let formatted = PersonNameComponentsFormatter().string(from: components)
            return formatted.isEmpty ? nil : formatted
        }
        let body = AppleSignInBody(
            idToken: idToken,
            nonce: nonce.nonce,
            user: name.map { AppleSignInBody.User(name: $0) }
        )
        let response: LuxSession = try await client.request(
            .post,
            path: "/auth/v1/signin/apple",
            body: body
        )
        try checkLifecycle(generation)
        let session = normalized(response)
        try persistAndSetSession(session, appleUserIdentifier: credential.user, event: .signedIn(session))
        return session
    }

    /// Run Google, GitHub, or Apple web OAuth using an ephemeral-capable native
    /// authentication session and exchange the returned one-time code.
    @discardableResult
    public func signInWithOAuth(
        _ provider: LuxOAuthProvider,
        redirectURL: URL,
        prefersEphemeralSession: Bool = false
    ) async throws -> LuxSession {
        guard let callbackScheme = redirectURL.scheme, !callbackScheme.isEmpty else {
            throw LuxConfigurationError.invalidURL
        }
        let generation = try beginLifecycleOperation()
        let pkce = try PKCE.generate()
        let authorizationURL = try client.authorizationURL(
            provider: provider,
            redirectURL: redirectURL,
            flow: .code,
            codeChallenge: pkce.challenge
        )
        let coordinator = OAuthWebCoordinator(presentationAnchorProvider: presentationAnchorProvider)
        webCoordinator = coordinator
        defer { if lifecycleGeneration == generation { webCoordinator = nil } }
        let callback = try await coordinator.perform(
            authorizationURL: authorizationURL,
            callbackScheme: callbackScheme,
            prefersEphemeralSession: prefersEphemeralSession
        )
        try checkLifecycle(generation)
        let components = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        if let error = components?.queryItems?.first(where: { $0.name == "error" })?.value {
            throw LuxError(code: "OAUTH_ERROR", message: error)
        }
        guard let code = components?.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw LuxError(code: "OAUTH_MISSING_CODE", message: "OAuth callback did not contain an authorization code")
        }
        return try await exchangeCodeForSession(
            code,
            codeVerifier: pkce.verifier,
            generation: generation
        )
    }

    @discardableResult
    public func exchangeCodeForSession(
        _ code: String,
        codeVerifier: String? = nil
    ) async throws -> LuxSession {
        let generation = try beginLifecycleOperation()
        return try await exchangeCodeForSession(
            code,
            codeVerifier: codeVerifier,
            generation: generation
        )
    }

    public func resetPassword(for email: String, redirectTo: URL? = nil) async throws {
        try await client.requestWithoutResponse(
            .post,
            path: "/auth/v1/recover",
            body: PasswordRecoveryBody(email: email, redirectTo: redirectTo?.absoluteString)
        )
    }

    @discardableResult
    public func verifyOTP(tokenHash: String, type: LuxOTPType) async throws -> LuxSession {
        let generation = try beginLifecycleOperation()
        let response: LuxSession = try await client.request(
            .post,
            path: "/auth/v1/verify",
            body: VerifyOTPBody(tokenHash: tokenHash, type: type.rawValue)
        )
        try checkLifecycle(generation)
        let session = normalized(response)
        try persistAndSetSession(session, appleUserIdentifier: nil, event: .signedIn(session))
        return session
    }

    @discardableResult
    public func updateUser(
        email: String? = nil,
        password: String? = nil,
        metadata: [String: LuxJSONValue]? = nil
    ) async throws -> LuxUser {
        try ensureLifecycleAvailable()
        let generation = lifecycleGeneration
        guard let expectedUserID = session?.user.id else {
            throw LuxError(code: "NO_SESSION", message: "No authenticated session")
        }
        let token = try await accessToken()
        try checkLifecycle(generation)
        let response: UserResponse = try await client.request(
            .put,
            path: "/auth/v1/user",
            body: UpdateUserBody(email: email, password: password, userMetadata: metadata),
            bearerToken: token
        )
        try checkLifecycle(generation)
        guard var current = session, current.user.id == expectedUserID else {
            throw CancellationError()
        }
        current.user = response.user
        try persistAndSetSession(
            current,
            appleUserIdentifier: appleUserIdentifier,
            event: .userUpdated(response.user)
        )
        return response.user
    }

    @discardableResult
    public func getUser() async throws -> LuxUser {
        try ensureLifecycleAvailable()
        let generation = lifecycleGeneration
        let token = try await accessToken()
        try checkLifecycle(generation)
        let response: UserResponse = try await client.request(
            .get,
            path: "/auth/v1/user",
            bearerToken: token
        )
        try checkLifecycle(generation)
        return response.user
    }

    /// Return a valid access token, sharing one refresh request across callers.
    public func accessToken(leeway: TimeInterval = 30) async throws -> String {
        try Task.checkCancellation()
        try ensureLifecycleAvailable()
        guard let session else {
            throw LuxError(code: "NO_SESSION", message: "No authenticated session")
        }
        if let expiresAt = session.expiresAt,
           TimeInterval(expiresAt) > now().timeIntervalSince1970 + leeway {
            return session.accessToken
        }
        return try await refreshSession().accessToken
    }

    @discardableResult
    public func refreshSession() async throws -> LuxSession {
        try ensureLifecycleAvailable()
        if let refreshTask {
            let session = try await refreshTask.value
            try Task.checkCancellation()
            return session
        }
        guard let current = session else {
            throw LuxError(code: "NO_SESSION", message: "No authenticated session")
        }

        let client = self.client
        let refreshToken = current.refreshToken
        let appleUserIdentifier = self.appleUserIdentifier
        let generation = lifecycleGeneration
        let refreshedAt = Int(now().timeIntervalSince1970)
        let task = Task { @MainActor [weak self] in
            try Task.checkCancellation()
            var response: LuxSession = try await client.request(
                .post,
                path: "/auth/v1/token",
                queryItems: [URLQueryItem(name: "grant_type", value: "refresh_token")],
                body: RefreshTokenBody(refreshToken: refreshToken)
            )
            try Task.checkCancellation()
            guard let self else { throw CancellationError() }
            try self.checkLifecycle(generation)
            response.expiresAt = refreshedAt + response.expiresIn
            try self.persistAndSetSession(
                response,
                appleUserIdentifier: appleUserIdentifier,
                event: .tokenRefreshed(response)
            )
            return response
        }
        refreshTask = task

        do {
            let refreshed = try await task.value
            if lifecycleGeneration == generation { refreshTask = nil }
            try Task.checkCancellation()
            return refreshed
        } catch {
            if lifecycleGeneration == generation {
                refreshTask = nil
                if let apiError = error as? LuxAPIError, apiError.invalidatesRefreshToken {
                    _ = invalidateLifecycle()
                    try? clearLocalSession()
                    emit(.signedOut)
                }
            }
            throw error
        }
    }

    /// Unregister dependent resources while the bearer token is valid, revoke
    /// the server session, and always clear local credentials.
    public func signOut() async throws {
        guard !isSigningOut else { throw CancellationError() }
        isSigningOut = true
        _ = invalidateLifecycle()
        defer { isSigningOut = false }
        let current = session
        var firstError: Error?
        if let current {
            // Snapshot before awaiting: an owner may be released and unregister
            // its handler while another cleanup callback is suspended.
            for handler in Array(preSignOutHandlers.values) {
                do { try await handler(current) }
                catch { if firstError == nil { firstError = error } }
            }
        }

        clearInMemorySession()
        do { try sessionStore.clear() }
        catch { if firstError == nil { firstError = error } }

        if let current {
            do {
                try await client.requestWithoutResponse(
                    .post,
                    path: "/auth/v1/logout",
                    body: RefreshTokenBody(refreshToken: current.refreshToken),
                    bearerToken: current.accessToken
                )
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        emit(.signedOut)
        if let firstError { throw firstError }
    }

    @discardableResult
    func addPreSignOutHandler(
        _ handler: @escaping @MainActor (LuxSession) async throws -> Void
    ) -> UUID {
        let id = UUID()
        preSignOutHandlers[id] = handler
        return id
    }

    func removePreSignOutHandler(_ id: UUID) {
        preSignOutHandlers.removeValue(forKey: id)
    }

    private func exchangeCodeForSession(
        _ code: String,
        codeVerifier: String?,
        generation: UInt64
    ) async throws -> LuxSession {
        let response: LuxSession = try await client.request(
            .post,
            path: "/auth/v1/token",
            queryItems: [URLQueryItem(name: "grant_type", value: "authorization_code")],
            body: AuthorizationCodeBody(code: code, codeVerifier: codeVerifier)
        )
        try checkLifecycle(generation)
        let session = normalized(response)
        try persistAndSetSession(session, appleUserIdentifier: nil, event: .signedIn(session))
        return session
    }

    private func normalized(_ session: LuxSession) -> LuxSession {
        var session = session
        session.expiresAt = Int(now().timeIntervalSince1970) + session.expiresIn
        return session
    }

    private func persistAndSetSession(
        _ session: LuxSession,
        appleUserIdentifier: String?,
        event: LuxAuthEvent
    ) throws {
        do {
            try sessionStore.save(LuxStoredSession(
                session: session,
                appleUserIdentifier: appleUserIdentifier
            ))
        } catch {
            _ = invalidateLifecycle()
            clearInMemorySession()
            do { try sessionStore.clear() }
            catch { throw LuxSessionPersistenceError.cleanupAfterSaveFailure }
            throw error
        }
        self.session = session
        self.appleUserIdentifier = appleUserIdentifier
        emit(event)
    }

    private func clearLocalSession() throws {
        clearInMemorySession()
        try sessionStore.clear()
    }

    private func clearInMemorySession() {
        session = nil
        appleUserIdentifier = nil
    }

    private func emit(_ event: LuxAuthEvent) {
        for continuation in eventContinuations.values { continuation.yield(event) }
    }

    @discardableResult
    private func invalidateLifecycle() -> UInt64 {
        lifecycleGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        appleCoordinator?.cancel()
        appleCoordinator = nil
        webCoordinator?.cancel()
        webCoordinator = nil
        return lifecycleGeneration
    }

    private func checkLifecycle(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard !isSigningOut, lifecycleGeneration == generation else { throw CancellationError() }
    }

    private func beginLifecycleOperation() throws -> UInt64 {
        try ensureLifecycleAvailable()
        return invalidateLifecycle()
    }

    private func ensureLifecycleAvailable() throws {
        guard !isSigningOut else { throw CancellationError() }
    }
}

public enum LuxSessionPersistenceError: Error, Sendable, Equatable {
    case cleanupAfterSaveFailure
}
