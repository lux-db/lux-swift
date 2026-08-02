import UIKit

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    var onDeviceToken: ((Data) async throws -> Void)?

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        guard let onDeviceToken else { return }
        Task {
            do { try await onDeviceToken(deviceToken) }
            catch {
                // Send the error to telemetry or user-visible app state.
                // Never include the device token itself.
                print("Lux push registration failed: \(error.localizedDescription)")
            }
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Report through your application's telemetry. Never log device tokens.
        print("Remote notification registration failed: \(error.localizedDescription)")
    }
}
