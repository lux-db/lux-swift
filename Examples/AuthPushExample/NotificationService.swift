import Foundation
import Lux
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private let completionLock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let content = request.content.mutableCopy() as! UNMutableNotificationContent
        completionLock.withLock {
            self.contentHandler = contentHandler
            bestAttemptContent = content
        }
        Task { [weak self] in
            self?.finish(with: await LuxPushAttachment.enrich(content))
        }
    }

    override func serviceExtensionTimeWillExpire() {
        let fallback = completionLock.withLock { bestAttemptContent }
        if let fallback {
            finish(with: fallback)
        }
    }

    private func finish(with content: UNNotificationContent) {
        let handler = completionLock.withLock {
            let handler = contentHandler
            contentHandler = nil
            bestAttemptContent = nil
            return handler
        }
        handler?(content)
    }
}
