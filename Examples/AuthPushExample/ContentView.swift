import Lux
import SwiftUI

struct ContentView: View {
    @Environment(LuxProject.self) private var lux
    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isBusy = false

    var body: some View {
        NavigationStack {
            Form {
                if let user = lux.auth.user {
                    Section("Signed in") {
                        Text(user.email ?? user.id)
                        Button("Sign out", role: .destructive) {
                            perform { try await lux.auth.signOut() }
                        }
                    }
                } else {
                    Section("Email") {
                        TextField("Email", text: $email)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                        SecureField("Password", text: $password)
                        Button("Sign in") {
                            perform {
                                try await lux.auth.signInWithPassword(
                                    email: email,
                                    password: password
                                )
                            }
                        }
                        Button("Create account") {
                            perform {
                                _ = try await lux.auth.signUp(
                                    email: email,
                                    password: password
                                )
                            }
                        }
                    }
                    Section {
                        Button("Sign in with Apple") {
                            perform { try await lux.auth.signInWithApple() }
                        }
                        Button("Continue anonymously") {
                            perform { try await lux.auth.signInAnonymously() }
                        }
                    }
                    Section("Web OAuth") {
                        Button("Continue with Google") {
                            perform { try await signInWithOAuth(.google) }
                        }
                        Button("Continue with GitHub") {
                            perform { try await signInWithOAuth(.github) }
                        }
                    }
                }
                Section("Push") {
                    LabeledContent(
                        "Permission",
                        value: authorizationStatus(lux.push.authorizationStatus)
                    )
                    LabeledContent(
                        "Registration",
                        value: registrationStatus
                    )
                    Button("Enable notifications") {
                        perform { _ = try await lux.push.requestAuthorization() }
                    }
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .disabled(isBusy)
            .navigationTitle("Lux Auth + Push")
        }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                try await operation()
                errorMessage = nil
            } catch is CancellationError {
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func signInWithOAuth(_ provider: LuxOAuthProvider) async throws {
        try await lux.auth.signInWithOAuth(
            provider,
            redirectURL: URL(string: "lux-example://auth/callback")!
        )
    }

    private func authorizationStatus(_ status: LuxPushAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "Not requested"
        case .denied: "Denied"
        case .authorized: "Authorized"
        case .provisional: "Provisional"
        case .ephemeral: "Ephemeral"
        }
    }

    private var registrationStatus: String {
        guard lux.push.registration != nil else { return "No token" }
        return lux.push.isRegistered ? "Registered" : "Pending sign-in"
    }
}
