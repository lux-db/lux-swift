# Auth + Push Example

These files show the complete Lux 1.1 integration in a SwiftUI application.

1. Create an iOS 17 app target in Xcode.
2. Add the `Lux` Swift package product.
3. Add `AuthPushExampleApp.swift`, `AppDelegate.swift`, and `ContentView.swift`
   to the app target.
4. Replace the project URL and publishable key.
5. Enable **Sign in with Apple** and **Push Notifications** capabilities.
6. Configure the custom URL scheme `lux-example` if using web OAuth.
7. For rich images, add a Notification Service Extension and use the included
   `NotificationService.swift` in that extension target.

The application delegate forwards only the APNs token and error callbacks. Lux
does not swizzle delegates or install global state.
