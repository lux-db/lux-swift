import Lux
import SwiftUI

struct ContentView: View {
    @Environment(LuxProject.self) private var lux
    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if let user = lux.auth.user {
                    Section("Signed in") {
                        Text(user.email ?? user.id)
                        Button("Enable notifications") {
                            perform { _ = try await lux.push.requestAuthorization() }
                        }
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
                    }
                    Section {
                        Button("Sign in with Apple") {
                            perform { try await lux.auth.signInWithApple() }
                        }
                        Button("Continue anonymously") {
                            perform { try await lux.auth.signInAnonymously() }
                        }
                    }
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("Lux Auth + Push")
        }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await operation()
                errorMessage = nil
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }
}
