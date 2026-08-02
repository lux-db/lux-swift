# ``Lux``

Authenticate users and register their Apple push-notification devices with a
Lux project.

## Overview

Create one ``LuxProject`` and place it in the SwiftUI environment. Its
``LuxProject/auth`` namespace owns durable session state; its
``LuxProject/push`` namespace owns the current APNs token and binds it to the
authenticated user. After permission is granted, call
``LuxPush/registerForRemoteNotifications()`` on each launch and forward every
Apple token callback to ``LuxPush/register(deviceToken:appID:)`` so token
rotation remains synchronized.

The package deliberately exposes no database, realtime, storage, notification
sending, or secret-key administration APIs.

## Topics

### Project

- ``LuxProject``
- ``LuxClient``
- ``LuxNetworkPolicy``

### Authentication

- ``LuxAuth``
- ``LuxSession``
- ``LuxUser``
- ``LuxAuthEvent``
- ``LuxOAuthProvider``
- ``LuxOAuthFlow``
- ``LuxAuthResult``
- ``LuxOTPType``
- ``LuxJSONValue``
- ``LuxAppleCredentialState``
- ``LuxAppleCredentialStateProviding``
- ``SystemAppleCredentialStateProvider``

### Push notifications

- ``LuxPush``
- ``LuxPushAuthorizationStatus``
- ``LuxPushAuthorizationOptions``
- ``LuxAPNSEnvironment``
- ``LuxPushDevice``
- ``LuxPushPayload``
- ``LuxPushAlert``
- ``LuxPushSound``
- ``LuxPushInterruptionLevel``
- ``LuxPushAttachment``

### Testing and configuration

- ``LuxTransport``
- ``LuxSessionStore``
- ``LuxStoredSession``
- ``KeychainLuxSessionStore``
- ``LuxPushRegistrationStore``
- ``LuxStoredPushRegistration``
- ``KeychainLuxPushRegistrationStore``
- ``LuxPushSystemProviding``
- ``SystemLuxPushProvider``
- ``LuxAPNSEnvironmentProviding``
- ``SystemLuxAPNSEnvironmentProvider``

### Errors

- ``LuxError``
- ``LuxAPIError``
- ``LuxConfigurationError``
- ``LuxSecurityError``
- ``LuxEncodingError``
- ``LuxResponseError``
- ``LuxSessionPersistenceError``
- ``LuxSessionStoreError``
- ``LuxPushStoreError``
