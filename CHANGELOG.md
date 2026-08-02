# Changelog

## 1.1.0

Lux Swift 1.1 turns the original Sign in with Apple package into the native
Auth + Push SDK for Lux engine 0.37.0 and newer.

### Added

- `LuxProject` with observable `auth` and `push` namespaces.
- Email/password signup and sign-in, anonymous sign-in, Google/GitHub/Apple web
  OAuth with PKCE, password recovery, OTP verification, user updates, and
  native Sign in with Apple.
- Durable Keychain sessions, single-flight refresh-token rotation, lifecycle
  events, Apple credential-state verification, and remote sign-out.
- Authenticated APNs permission, token registration, bundle/topic association,
  launch-time token refresh, token rotation, device listing, sign-out cleanup,
  and next-user reassociation.
- Typed standard APNs payload parsing and a validated rich-image attachment
  helper for Notification Service Extensions.
- An explicit local-development network policy for private LAN engines while
  preserving HTTPS-by-default behavior for remote projects.
- A complete SwiftUI/Auth/Push sample and opt-in real-engine contract tests.

### Security

- Mobile clients reject Lux secret-key prefixes.
- Native OAuth codes are bound to an ephemeral S256 PKCE verifier.
- User device registration never accepts a caller-supplied subject identifier.
- Public HTTP hosts remain rejected, including deceptive hostnames that resemble
  private IPv6 prefixes.

### Compatibility

- The 1.0 `LuxClient` and `LuxAuth` initializer surface remains source
  compatible, and existing Keychain sessions require no migration.
- Requires iOS 17 or macOS 14 and Swift 6.
- Requires Lux engine 0.37.0 or newer for PKCE-bound native OAuth and safe
  authenticated APNs token cleanup.
- Database, realtime, vectors, time series, storage, notification sending, and
  admin/secret-key APIs remain intentionally out of scope.

## 1.0.0

- Added native Sign in with Apple, durable Keychain session restoration,
  refresh-token rotation, and sign-out for iOS and macOS applications.
