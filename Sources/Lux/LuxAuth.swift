import AuthenticationServices
import Foundation
import Observation

/// Observable auth store for SwiftUI. Drop it into the environment; views read
/// `session`/`isAuthenticated` and re-render on sign-in and sign-out.
///
/// This seed implements Sign in with Apple end to end against Lux's
/// `POST /auth/v1/signin/apple`. Password, OAuth, refresh, and Keychain-backed
/// persistence layer onto the same store.
@MainActor
@Observable
public final class LuxAuth {
    public private(set) var session: LuxSession?
    public var user: LuxUser? { session?.user }
    public var isAuthenticated: Bool { session != nil }

    private let client: LuxClient
    private var appleCoordinator: AppleSignInCoordinator?

    public init(client: LuxClient) {
        self.client = client
    }

    /// Present the native Sign in with Apple sheet, verify the identity token
    /// with Lux, and store the resulting session.
    @discardableResult
    public func signInWithApple() async throws -> LuxSession {
        let rawNonce = Nonce.random()
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Nonce.sha256Hex(rawNonce)

        let coordinator = AppleSignInCoordinator()
        self.appleCoordinator = coordinator
        let credential = try await coordinator.perform(request: request)
        self.appleCoordinator = nil

        guard
            let tokenData = credential.identityToken,
            let idToken = String(data: tokenData, encoding: .utf8)
        else {
            throw LuxError(code: "APPLE_NO_IDENTITY_TOKEN", message: "Apple returned no identity token")
        }

        // Apple gives the name only on the first authorization; forward it so
        // Lux can persist it (subsequent sign-ins omit it).
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
        let session = try await client.postJSON(
            path: "/auth/v1/signin/apple",
            body: body,
            as: LuxSession.self
        )
        self.session = session
        return session
    }

    public func signOut() {
        session = nil
    }
}

private struct AppleSignInBody: Encodable {
    let idToken: String
    let nonce: String
    let user: User?

    struct User: Encodable {
        let name: String
    }

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case nonce
        case user
    }
}

/// Bridges ASAuthorizationController's delegate callbacks into async/await.
@MainActor
private final class AppleSignInCoordinator: NSObject,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding
{
    private var continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?

    func perform(request: ASAuthorizationAppleIDRequest) async throws -> ASAuthorizationAppleIDCredential {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            continuation?.resume(throwing: LuxError(
                code: "APPLE_WRONG_CREDENTIAL",
                message: "unexpected Apple credential type"
            ))
            continuation = nil
            return
        }
        continuation?.resume(returning: credential)
        continuation = nil
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow }
        return window ?? UIWindow()
        #else
        return NSApplication.shared.keyWindow ?? NSWindow()
        #endif
    }
}

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
