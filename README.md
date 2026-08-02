# Lux Swift

The native Lux SDK for authentication and push notifications on iOS 17+ and
macOS 14+. It keeps user sessions in Keychain, refreshes them safely, presents
native Apple or web OAuth, and registers APNs tokens directly to the currently
authenticated Lux user.

The mobile SDK accepts a publishable key only. Database access, realtime,
storage, notification sending, and secret-key administration are intentionally
outside the 1.1 surface.

## Installation

Add `https://github.com/lux-db/lux-swift` as a Swift Package dependency and
select the `1.1.0` release.

## Compatibility

Lux Swift 1.1 requires Lux engine 0.37.0 or newer. That engine release binds
native OAuth authorization codes with PKCE and allows authenticated apps to
remove only their own APNs tokens during rotation and sign-out. For a local
CLI-managed project, run `lux update engine` before adopting 1.1. For Lux
Cloud, update the project from Project Settings or run
`lux update engine <project>` after engine 0.37.0 is published.

### Migrating from 1.0

The 1.1 API is additive. Existing `LuxClient` and `LuxAuth` initializers remain
source compatible, and the release gate compares the package against the
`1.0.0` public API. Existing Keychain sessions continue using the same service
and project-URL account, so no token migration is required.

To adopt the new surface:

1. Update the Lux engine to 0.37.0 or newer.
2. Prefer one `LuxProject` over separately constructing the client and auth
   objects; its `auth` namespace uses the same durable session format.
3. Add the Push Notifications capability, forward the APNs delegate token to
   `project.push.register(deviceToken:)`, and request permission from an
   explicit user action.
4. For a physical device talking to a cleartext LAN engine, opt into
   `.localDevelopment`; remote URLs remain HTTPS-only.

No database, realtime, storage, sending, or admin APIs are introduced by this
upgrade.

## Create a project

Create one `LuxProject` for the application:

```swift
import Lux
import SwiftUI

@main
struct ExampleApp: App {
    @State private var lux = try! LuxProject(
        url: "https://api.luxdb.dev/v1/your-project",
        publishableKey: "lux_pub_..."
    )

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(lux)
                .task { try? await lux.auth.restoreSession() }
        }
    }
}
```

Remote project URLs must use HTTPS. Plain HTTP is accepted automatically for
`localhost`, `127.0.0.1`, and `::1`. A development app can explicitly opt into
a private LAN engine without weakening public-host validation:

```swift
let lux = try LuxProject(
    url: "http://192.168.1.50:15890",
    publishableKey: "lux_pub_...",
    networkPolicy: .localDevelopment
)
```

`.localDevelopment` accepts private IPv4 ranges, local/unique-local IPv6, and
local hostnames; it still rejects public cleartext endpoints. The SDK rejects
`lux_sec_` secret keys (and the legacy `lux_sk_` alias) so they cannot
accidentally ship in a mobile application.

## Authentication

```swift
// Native Sign in with Apple
try await lux.auth.signInWithApple()

// Email/password
try await lux.auth.signUp(email: email, password: password)
try await lux.auth.signInWithPassword(email: email, password: password)

// Anonymous session
try await lux.auth.signInAnonymously()

// Google or GitHub in ASWebAuthenticationSession
try await lux.auth.signInWithOAuth(
    .google,
    redirectURL: URL(string: "myapp://auth/callback")!
)
```

Web OAuth uses an ephemeral, in-memory PKCE verifier and an S256 challenge.
The authorization code is therefore redeemable only by the SDK instance that
started the native session, including when the callback uses a custom URL
scheme.

If the user dismisses the native Apple sheet or OAuth browser, the operation
throws Swift's standard `CancellationError`. Treat that as a quiet cancellation
rather than an authentication failure.

Add the exact native callback (for example `myapp://auth/callback`) to the
project's Auth redirect allow list in Studio or Cloud. Google, GitHub, and Apple
developer consoles use the Lux engine's HTTPS provider callback shown by that
provider configuration—not the app's custom URL. A local engine therefore needs
a public HTTPS route only for the provider callback; the app can still talk to
the engine directly over its trusted LAN address.

Password recovery and verification links use the same durable session path:

```swift
try await lux.auth.resetPassword(
    for: email,
    redirectTo: URL(string: "myapp://auth/recovery")!
)

// Parse token_hash and type from the incoming application URL.
try await lux.auth.verifyOTP(tokenHash: tokenHash, type: .recovery)
try await lux.auth.updateUser(password: replacementPassword)
```

Use `updateUser(email:password:metadata:)` for authenticated profile changes,
`getUser()` to revalidate the server user, and `accessToken()` when an app-owned
backend needs the current bearer token. `accessToken()` refreshes automatically;
applications should never read or persist refresh tokens themselves.

`LuxAuth` is observable. `session`, `user`, and `isAuthenticated` update
SwiftUI automatically. For non-view consumers, `auth.events()` is an
`AsyncStream` of initial-session, sign-in, refresh, user-update, and sign-out
events.

Sessions are stored in Keychain by default. Token refresh is single-flight, so
concurrent callers share one rotation request. `signOut()` clears local state
even if remote cleanup fails and reports the cleanup error to the caller.

## Push notifications

First configure APNs credentials for the Lux project in Cloud or Studio. In the
app, request permission:

```swift
let status = try await lux.push.requestAuthorization()
```

The default request asks for alerts, badges, and sounds. Advanced applications
can additionally request provisional delivery, critical alerts, CarPlay, or an
app-owned notification-settings screen with `LuxPushAuthorizationOptions`.
Critical alerts and CarPlay still require the corresponding Apple entitlement;
requesting an option does not grant that entitlement.

Forward Apple's application-delegate token callback to Lux:

```swift
func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
) {
    Task { try await lux.push.register(deviceToken: deviceToken) }
}
```

After notification permission has already been granted, ask Apple for the
current token on each launch without prompting again:

```swift
let status = await lux.push.refreshAuthorizationStatus()
if status == .authorized || status == .provisional || status == .ephemeral {
    lux.push.registerForRemoteNotifications()
}
```

Apple may rotate the token between launches; every delegate callback should be
forwarded to `register(deviceToken:)`, even when the value appears unchanged.

Registration uses the application bundle identifier as `app_id` automatically,
matching the APNs topic configured for the project. Pass `appID:` only when the
project deliberately uses a different credential key.

That is the only required callback. The SDK:

- converts the binary token to APNs hex;
- records sandbox or production per device;
- holds the token pending when the user is signed out;
- registers it after sign-in or session restoration;
- lets the engine derive the subject from the bearer session—no user id is
  accepted from the app;
- durably remembers superseded tokens, removes their old device rows, and
  retries cleanup after transient failures; and
- waits for any in-flight registration, then removes current and superseded
  tokens before revoking the session on sign-out.

Xcode Debug and Simulator builds default to APNs sandbox; Release builds
default to production. Custom signing configurations can set
`LuxAPNSEnvironment` to `sandbox` or `production` in the application Info.plist,
or call `register(token:environment:)` explicitly.

Parse custom notification data without manually traversing `aps`:

```swift
let payload = LuxPushPayload(userInfo: response.notification.request.content.userInfo)
route(payload.data)
```

`LuxPushPayload` also types APNs alert localization, named and critical sounds,
interruption level, relevance score, target-content id, background delivery,
mutable content, category, thread, badge, and image URL fields.

For image notifications, add a Notification Service Extension and enrich the
mutable content before delivery:

```swift
let content = request.content.mutableCopy() as! UNMutableNotificationContent
contentHandler(await LuxPushAttachment.enrich(content))
```

The helper accepts HTTPS responses with an image MIME type and a verified file
size up to 10 MB. It always falls back to the original notification if
validation, download, or attachment creation fails.

See [`Examples/AuthPushExample`](Examples/AuthPushExample) for complete SwiftUI,
application-delegate, and notification-service-extension wiring.

## Testing

```bash
swift test
xcodebuild build \
  -scheme Lux \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

Inject `LuxTransport`, `LuxSessionStore`, `LuxPushRegistrationStore`,
`LuxPushSystemProviding`, or `LuxAPNSEnvironmentProviding` to test without
Keychain, network, or notification permission dialogs.

The opt-in engine contract test runs when both variables are present:

```bash
LUX_INTEGRATION_URL=http://127.0.0.1:5890 \
LUX_INTEGRATION_PUBLISHABLE_KEY=lux_pub_... \
swift test --filter LuxIntegrationTests
```

When the test engine is deliberately bound to a private LAN address, also set
`LUX_INTEGRATION_LOCAL_DEVELOPMENT=true`. The harness otherwise keeps the
SDK's secure network policy.

Never log access tokens, refresh tokens, Apple identity tokens, APNs device
tokens, nonces, or authorization headers.

## Release

Tags use semantic versions. Pushing `1.1.0` runs the release workflow, tests the
package, builds it for iOS Simulator, verifies it against the minimum supported
engine, and creates the GitHub Release. Follow [`RELEASING.md`](RELEASING.md)
so the engine compatibility tag exists before the SDK tag is created.
