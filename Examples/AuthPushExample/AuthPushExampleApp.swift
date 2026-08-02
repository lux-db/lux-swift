import Lux
import SwiftUI

@main
struct AuthPushExampleApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var lux = try! LuxProject(
        url: "https://api.luxdb.dev/v1/your-project",
        publishableKey: "lux_pub_replace_me"
    )

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(lux)
                .task {
                    appDelegate.onDeviceToken = { [lux] token in
                        try await lux.push.register(deviceToken: token)
                    }
                    _ = try? await lux.auth.restoreSession()
                    let status = await lux.push.refreshAuthorizationStatus()
                    switch status {
                    case .authorized, .provisional, .ephemeral:
                        // Apple can rotate the token between launches. This
                        // does not present another permission prompt.
                        lux.push.registerForRemoteNotifications()
                    case .notDetermined, .denied:
                        break
                    }
                }
        }
    }
}
