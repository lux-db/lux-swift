# Auth + Push Example

These files show the complete Lux 1.1 integration in a SwiftUI application:
email/password signup and sign-in, native Apple auth, Google/GitHub PKCE,
anonymous auth, durable restoration, APNs permission and registration, and a
rich-image notification extension.

1. Create an iOS 17 app target in Xcode.
2. Add the `Lux` Swift package product.
3. Add `AuthPushExampleApp.swift`, `AppDelegate.swift`, and `ContentView.swift`
   to the app target.
4. Replace the project URL and publishable key.
5. Enable **Sign in with Apple** and **Push Notifications** capabilities.
6. Configure the custom URL scheme `lux-example` and allow
   `lux-example://auth/callback` in the Lux project's Auth redirect settings if
   using web OAuth. Provider consoles still use the engine's HTTPS callback
   shown in Studio or Cloud.
7. For rich images, add a Notification Service Extension and use the included
   `NotificationService.swift` in that extension target.

The application delegate forwards only the APNs token and error callbacks. Lux
does not swizzle delegates or install global state. The app also calls
`registerForRemoteNotifications()` on later authorized launches so Apple token
rotation reaches the same delegate callback without presenting another prompt.
