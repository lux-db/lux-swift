# ``Lux``

Authenticate users and register their Apple push-notification devices with a
Lux project.

## Overview

Create one ``LuxProject`` and place it in the SwiftUI environment. Its
``LuxProject/auth`` namespace owns durable session state; its
``LuxProject/push`` namespace owns the current APNs token and binds it to the
authenticated user.

The package deliberately exposes no database, realtime, storage, notification
sending, or secret-key administration APIs.

## Topics

### Project

- ``LuxProject``
- ``LuxClient``

### Authentication

- ``LuxAuth``
- ``LuxSession``
- ``LuxUser``
- ``LuxAuthEvent``
- ``LuxOAuthProvider``
- ``LuxAuthResult``
- ``LuxOTPType``

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
