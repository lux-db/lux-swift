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
                case .authorized:
                    continuation.resume(returning: .authorized)
                case .revoked:
                    continuation.resume(returning: .revoked)
                case .transferred:
                    continuation.resume(returning: .transferred)
                case .notFound:
                    continuation.resume(returning: .notFound)
                @unknown default:
                    continuation.resume(returning: .notFound)
                }
            }
        }
    }
}

/// Observable auth store for SwiftUI with durable session lifecycle management.
@MainActor
@Observable
public final class LuxAuth {
    public private(set) var session: LuxSession?
    public var user: LuxUser? { session?.user }
    public var isAuthenticated: Bool { session != nil }

    private let client: LuxClient
    private let sessionStore: any LuxSessionStore
    private let credentialStateProvider: any LuxAppleCredentialStateProviding
    private let presentationAnchorProvider: () -> ASPresentationAnchor?
    private let now: @Sendable () -> Date
    private var appleCoordinator: AppleSignInCoordinator?
    private var appleUserIdentifier: String?
    private var refreshTask: Task<LuxSession, Error>?
    private var lifecycleGeneration: UInt64 = 0

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

    /// Restore a persisted session, checking Apple authorization when the session
    /// originated from Sign in with Apple.
    @discardableResult
    public func restoreSession() async throws -> LuxSession? {
        let generation = invalidateLifecycle()
        try checkLifecycle(generation)
        guard let stored = try sessionStore.load() else {
            clearInMemorySession()
            return nil
        }

        if let appleUserID = stored.appleUserIdentifier {
            let state = try await credentialStateProvider.credentialState(forUserID: appleUserID)
            try checkLifecycle(generation)
            guard state == .authorized else {
                try clearLocalSession()
                return nil
            }
        }

        try checkLifecycle(generation)
        session = stored.session
        appleUserIdentifier = stored.appleUserIdentifier
        return session
    }

    /// Present the native Sign in with Apple sheet and exchange its identity token.
    @discardableResult
    public func signInWithApple() async throws -> LuxSession {
        let generation = invalidateLifecycle()
        try checkLifecycle(generation)
        let rawNonce = try await client.appleSignInNonce()
        try checkLifecycle(generation)

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Nonce.sha256Hex(rawNonce)

        let coordinator = AppleSignInCoordinator(
            presentationAnchorProvider: presentationAnchorProvider
        )
        appleCoordinator = coordinator
        defer {
            if lifecycleGeneration == generation {
                appleCoordinator = nil
            }
        }
        let credential = try await coordinator.perform(request: request)
        try checkLifecycle(generation)

        guard
            let tokenData = credential.identityToken,
            let idToken = String(data: tokenData, encoding: .utf8)
        else {
            throw LuxError(code: "APPLE_NO_IDENTITY_TOKEN", message: "Apple returned no identity token")
        }

        let name = credential.fullName.flatMap { components -> String? in
            let formatter = PersonNameComponentsFormatter()
            let formatted = formatter.string(from: components)
            return formatted.isEmpty ? nil : formatted
        }
        let body = AppleSignInBody(
            idToken: idToken,
            nonce: rawNonce,
            user: name.map { AppleSignInBody.User(name: $0) }
        )
        let newSession = normalized(try await client.signInWithApple(body))
        try checkLifecycle(generation)
        try persistAndSetSession(newSession, appleUserIdentifier: credential.user)
        return newSession
    }

    /// Return a valid access token, sharing one refresh request across callers.
    public func accessToken(leeway: TimeInterval = 30) async throws -> String {
        try Task.checkCancellation()
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
            var session = try await client.refreshSession(refreshToken: refreshToken)
            try Task.checkCancellation()
            guard let self else { throw CancellationError() }
            try self.checkLifecycle(generation)
            session.expiresAt = refreshedAt + session.expiresIn
            try self.persistAndSetSession(
                session,
                appleUserIdentifier: appleUserIdentifier
            )
            return session
        }
        refreshTask = task

        do {
            let refreshed = try await task.value
            if lifecycleGeneration == generation {
                refreshTask = nil
            }
            try Task.checkCancellation()
            return refreshed
        } catch {
            if lifecycleGeneration == generation {
                refreshTask = nil
                if let apiError = error as? LuxAPIError, apiError.invalidatesRefreshToken {
                    _ = invalidateLifecycle()
                    try? clearLocalSession()
                }
            }
            throw error
        }
    }

    /// Clear local state and revoke the captured server session.
    public func signOut() async throws {
        let current = session
        _ = invalidateLifecycle()
        clearInMemorySession()

        var storeError: Error?
        do {
            try sessionStore.clear()
        } catch {
            storeError = error
        }

        var remoteError: Error?
        if let current {
            do {
                try Task.checkCancellation()
                try await client.logout(
                    accessToken: current.accessToken,
                    refreshToken: current.refreshToken
                )
                try Task.checkCancellation()
            } catch {
                remoteError = error
            }
        }
        if let remoteError {
            throw remoteError
        }
        if let storeError {
            throw storeError
        }
    }

    private func normalized(_ session: LuxSession) -> LuxSession {
        var session = session
        session.expiresAt = Int(now().timeIntervalSince1970) + session.expiresIn
        return session
    }

    private func persistAndSetSession(_ session: LuxSession, appleUserIdentifier: String?) throws {
        do {
            try sessionStore.save(LuxStoredSession(
                session: session,
                appleUserIdentifier: appleUserIdentifier
            ))
        } catch {
            _ = invalidateLifecycle()
            clearInMemorySession()
            do {
                try sessionStore.clear()
            } catch {
                throw LuxSessionPersistenceError.cleanupAfterSaveFailure
            }
            throw error
        }
        self.session = session
        self.appleUserIdentifier = appleUserIdentifier
    }

    private func clearLocalSession() throws {
        clearInMemorySession()
        try sessionStore.clear()
    }

    private func clearInMemorySession() {
        session = nil
        appleUserIdentifier = nil
    }

    @discardableResult
    private func invalidateLifecycle() -> UInt64 {
        lifecycleGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        appleCoordinator?.cancel()
        appleCoordinator = nil
        return lifecycleGeneration
    }

    private func checkLifecycle(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard lifecycleGeneration == generation else {
            throw CancellationError()
        }
    }
}

public enum LuxSessionPersistenceError: Error, Sendable, Equatable {
    case cleanupAfterSaveFailure
}

/// Bridges ASAuthorizationController delegate callbacks into async/await.
@MainActor
private final class AppleSignInCoordinator: NSObject,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding
{
    private let presentationAnchorProvider: () -> ASPresentationAnchor?
    private var continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?
    private var controller: ASAuthorizationController?
    private var presentationAnchor: ASPresentationAnchor?

    init(presentationAnchorProvider: @escaping () -> ASPresentationAnchor?) {
        self.presentationAnchorProvider = presentationAnchorProvider
    }

    func perform(request: ASAuthorizationAppleIDRequest) async throws -> ASAuthorizationAppleIDCredential {
        guard let anchor = presentationAnchorProvider() ?? Self.defaultPresentationAnchor() else {
            throw LuxError(
                code: "APPLE_NO_PRESENTATION_ANCHOR",
                message: "Sign in with Apple requires a visible presentation window"
            )
        }
        presentationAnchor = anchor
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let controller = ASAuthorizationController(authorizationRequests: [request])
                self.controller = controller
                controller.delegate = self
                controller.presentationContextProvider = self
                controller.performRequests()
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            finish(.failure(LuxError(
                code: "APPLE_WRONG_CREDENTIAL",
                message: "Unexpected Apple credential type"
            )))
            return
        }
        finish(.success(credential))
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        finish(.failure(error))
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        presentationAnchor!
    }

    private static func defaultPresentationAnchor() -> ASPresentationAnchor? {
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        return scenes.flatMap(\.windows).first { $0.isKeyWindow }
        #else
        return NSApplication.shared.keyWindow
            ?? NSApplication.shared.windows.first { $0.isVisible }
        #endif
    }

    fileprivate func cancel() {
        controller?.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<ASAuthorizationAppleIDCredential, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        controller = nil
        presentationAnchor = nil
        continuation.resume(with: result)
    }
}

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
