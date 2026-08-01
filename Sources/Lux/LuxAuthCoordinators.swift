import AuthenticationServices
import Foundation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
final class AppleSignInCoordinator: NSObject,
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
        guard let anchor = presentationAnchorProvider() ?? defaultPresentationAnchor() else {
            throw LuxError(code: "APPLE_NO_PRESENTATION_ANCHOR", message: "Sign in with Apple requires a visible presentation window")
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
            finish(.failure(LuxError(code: "APPLE_WRONG_CREDENTIAL", message: "Unexpected Apple credential type")))
            return
        }
        finish(.success(credential))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        finish(.failure(error))
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        presentationAnchor!
    }

    func cancel() {
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

@MainActor
final class OAuthWebCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let presentationAnchorProvider: () -> ASPresentationAnchor?
    private var session: ASWebAuthenticationSession?
    private var presentationAnchor: ASPresentationAnchor?

    init(presentationAnchorProvider: @escaping () -> ASPresentationAnchor?) {
        self.presentationAnchorProvider = presentationAnchorProvider
    }

    func perform(
        authorizationURL: URL,
        callbackScheme: String,
        prefersEphemeralSession: Bool
    ) async throws -> URL {
        guard let anchor = presentationAnchorProvider() ?? defaultPresentationAnchor() else {
            throw LuxError(code: "OAUTH_NO_PRESENTATION_ANCHOR", message: "OAuth requires a visible presentation window")
        }
        presentationAnchor = anchor
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = ASWebAuthenticationSession(
                    url: authorizationURL,
                    callbackURLScheme: callbackScheme
                ) { [weak self] url, error in
                    self?.session = nil
                    self?.presentationAnchor = nil
                    if let error { continuation.resume(throwing: error) }
                    else if let url { continuation.resume(returning: url) }
                    else { continuation.resume(throwing: LuxError(code: "OAUTH_EMPTY_CALLBACK", message: "OAuth returned no callback URL")) }
                }
                self.session = session
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = prefersEphemeralSession
                guard session.start() else {
                    self.session = nil
                    self.presentationAnchor = nil
                    continuation.resume(throwing: LuxError(code: "OAUTH_START_FAILED", message: "OAuth browser session could not start"))
                    return
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        presentationAnchor!
    }

    func cancel() {
        session?.cancel()
        session = nil
        presentationAnchor = nil
    }
}

@MainActor
private func defaultPresentationAnchor() -> ASPresentationAnchor? {
    #if os(iOS)
    let scenes = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .filter { $0.activationState == .foregroundActive }
    return scenes.flatMap(\.windows).first { $0.isKeyWindow }
    #else
    return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first { $0.isVisible }
    #endif
}
