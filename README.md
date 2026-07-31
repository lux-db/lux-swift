# Lux Swift

Lux Swift supports iOS 17 and macOS 14. It requests a server-issued one-time nonce, uses it with the native Sign in with Apple sheet, exchanges the Apple identity token with Lux, and stores sessions in Keychain by default.

## Installation

Add `https://github.com/lux-db/lux-swift` as a Swift Package dependency and
select a `1.x` release. Until the first release is tagged, add this checkout as
a local package in Xcode for integration testing.

## Usage

Create one client and auth store for your app:

```swift
import Lux
import SwiftUI

@main
struct ExampleApp: App {
    @State private var auth: LuxAuth

    init() {
        let client: LuxClient
        do {
            client = try LuxClient(
                url: "https://api.luxdb.dev/v1/your-project",
                publishableKey: "your-publishable-key"
            )
        } catch {
            fatalError("Invalid Lux project URL: \(error)")
        }
        _auth = State(initialValue: LuxAuth(client: client))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(auth)
                .task {
                    try? await auth.restoreSession()
                }
        }
    }
}
```

Start the native Apple authorization flow:

```swift
try await auth.signInWithApple()
```

Apps with more than one window should provide the presentation anchor that owns
the sign-in UI:

```swift
let auth = LuxAuth(client: client) { window }
```

Remote project URLs must use HTTPS. Plain HTTP is accepted only for
`localhost`, `127.0.0.1`, and `::1`; URL credentials, query strings, and
fragments are rejected with `LuxConfigurationError`.

Get a usable access token. The auth store refreshes an expired or nearly expired token and serializes concurrent refresh attempts:

```swift
let accessToken = try await auth.accessToken()
```

Sign out remotely and clear the local Keychain session:

```swift
try await auth.signOut()
```

`signOut()` clears local state even when the remote logout request fails, then rethrows the server or transport error. Apps can catch that error for telemetry without retaining a stale local login.

## Testing

Inject an implementation of `LuxTransport` to inspect or stub network requests,
and an implementation of `LuxSessionStore` to keep tests independent of
Keychain. For example, a test that does not need persistence can use this
ephemeral store:

```swift
private struct EphemeralSessionStore: LuxSessionStore {
    func load() throws -> LuxStoredSession? { nil }
    func save(_ storedSession: LuxStoredSession) throws {}
    func clear() throws {}
}

@MainActor
func makeTestAuth(client: LuxClient) -> LuxAuth {
    LuxAuth(
        client: client,
        sessionStore: EphemeralSessionStore()
    )
}
```

Never log access tokens, refresh tokens, Apple identity tokens, nonces, or authorization headers.

## Release

1. Require the `Swift` CI workflow on the default branch.
2. Run `swift test` from a clean checkout.
3. Tag the reviewed release as `1.0.0` and push the tag.

Swift Package Manager resolves releases directly from Git tags. Pushing a
semantic-version tag runs the release workflow and creates the corresponding
GitHub Release; no package registry publication is required.

Subsequent releases follow semantic versioning. Additive APIs increment the
minor version; source-breaking changes increment the major version.
