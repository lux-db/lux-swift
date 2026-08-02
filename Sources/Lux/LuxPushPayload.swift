import Foundation
import UserNotifications

public struct LuxPushAlert: Sendable, Equatable {
    public let title: String?
    public let subtitle: String?
    public let body: String?
    public let titleLocalizationKey: String?
    public let titleLocalizationArguments: [String]
    public let subtitleLocalizationKey: String?
    public let subtitleLocalizationArguments: [String]
    public let bodyLocalizationKey: String?
    public let bodyLocalizationArguments: [String]
    public let launchImage: String?

    public init(
        title: String? = nil,
        subtitle: String? = nil,
        body: String? = nil,
        titleLocalizationKey: String? = nil,
        titleLocalizationArguments: [String] = [],
        subtitleLocalizationKey: String? = nil,
        subtitleLocalizationArguments: [String] = [],
        bodyLocalizationKey: String? = nil,
        bodyLocalizationArguments: [String] = [],
        launchImage: String? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.titleLocalizationKey = titleLocalizationKey
        self.titleLocalizationArguments = titleLocalizationArguments
        self.subtitleLocalizationKey = subtitleLocalizationKey
        self.subtitleLocalizationArguments = subtitleLocalizationArguments
        self.bodyLocalizationKey = bodyLocalizationKey
        self.bodyLocalizationArguments = bodyLocalizationArguments
        self.launchImage = launchImage
    }
}

public enum LuxPushSound: Sendable, Equatable {
    case named(String)
    case critical(name: String, volume: Double?)
}

public enum LuxPushInterruptionLevel: String, Sendable, Equatable {
    case passive
    case active
    case timeSensitive = "time-sensitive"
    case critical
}

public struct LuxPushPayload: Sendable, Equatable {
    public let alert: LuxPushAlert
    public let badge: Int?
    public let category: String?
    public let threadID: String?
    public let sound: LuxPushSound?
    public let interruptionLevel: LuxPushInterruptionLevel?
    public let relevanceScore: Double?
    public let targetContentID: String?
    public let contentAvailable: Bool
    public let mutableContent: Bool
    public let filterCriteria: String?
    public let imageURL: URL?
    public let data: [String: LuxJSONValue]

    public init(userInfo: [AnyHashable: Any]) {
        let aps = userInfo["aps"] as? [String: Any] ?? [:]
        let alertValue = aps["alert"]
        let alert: LuxPushAlert
        if let body = alertValue as? String {
            alert = LuxPushAlert(title: nil, subtitle: nil, body: body)
        } else {
            let values = alertValue as? [String: Any] ?? [:]
            alert = LuxPushAlert(
                title: values["title"] as? String,
                subtitle: values["subtitle"] as? String,
                body: values["body"] as? String,
                titleLocalizationKey: values["title-loc-key"] as? String,
                titleLocalizationArguments: values["title-loc-args"] as? [String] ?? [],
                subtitleLocalizationKey: values["subtitle-loc-key"] as? String,
                subtitleLocalizationArguments: values["subtitle-loc-args"] as? [String] ?? [],
                bodyLocalizationKey: values["loc-key"] as? String,
                bodyLocalizationArguments: values["loc-args"] as? [String] ?? [],
                launchImage: values["launch-image"] as? String
            )
        }
        self.alert = alert
        self.badge = aps["badge"] as? Int
        self.category = aps["category"] as? String
        self.threadID = aps["thread-id"] as? String
        if let name = aps["sound"] as? String {
            self.sound = .named(name)
        } else if let critical = aps["sound"] as? [String: Any],
                  (critical["critical"] as? NSNumber)?.intValue == 1,
                  let name = critical["name"] as? String {
            self.sound = .critical(
                name: name,
                volume: (critical["volume"] as? NSNumber)?.doubleValue
            )
        } else {
            self.sound = nil
        }
        self.interruptionLevel = (aps["interruption-level"] as? String)
            .flatMap(LuxPushInterruptionLevel.init(rawValue:))
        self.relevanceScore = (aps["relevance-score"] as? NSNumber)?.doubleValue
        self.targetContentID = aps["target-content-id"] as? String
        self.contentAvailable = (aps["content-available"] as? NSNumber)?.intValue == 1
        self.mutableContent = (aps["mutable-content"] as? NSNumber)?.intValue == 1
        self.filterCriteria = aps["filter-criteria"] as? String
        self.imageURL = (userInfo["image_url"] as? String).flatMap(URL.init(string:))
        var data: [String: LuxJSONValue] = [:]
        for (key, value) in userInfo where String(describing: key) != "aps" && String(describing: key) != "image_url" {
            if let converted = LuxJSONValue(any: value) { data[String(describing: key)] = converted }
        }
        self.data = data
    }
}

public enum LuxPushAttachment {
    public static func enrich(
        _ content: UNMutableNotificationContent,
        session: URLSession = .shared,
        maximumBytes: Int64 = 10 * 1_024 * 1_024
    ) async -> UNMutableNotificationContent {
        guard
            maximumBytes > 0,
            let rawURL = content.userInfo["image_url"] as? String,
            let url = URL(string: rawURL),
            url.scheme?.lowercased() == "https"
        else { return content }

        do {
            let (temporaryURL, response) = try await session.download(from: url)
            guard response.url?.scheme?.lowercased() == "https" else { return content }
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                return content
            }
            guard response.mimeType?.lowercased().hasPrefix("image/") == true else {
                return content
            }
            if response.expectedContentLength > maximumBytes { return content }
            let values = try temporaryURL.resourceValues(forKeys: [.fileSizeKey])
            guard let fileSize = values.fileSize, Int64(fileSize) <= maximumBytes else {
                return content
            }
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "lux-push-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileName = attachmentFileName(url: url, response: response)
            let destination = directory.appending(path: fileName)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            let attachment = try UNNotificationAttachment(identifier: "lux-image", url: destination)
            content.attachments.append(attachment)
        } catch {
            // Notification service extensions have strict execution budgets;
            // the original notification must still be delivered on any error.
        }
        return content
    }

    private static func attachmentFileName(url: URL, response: URLResponse) -> String {
        let suggested = response.suggestedFilename.map { URL(filePath: $0).lastPathComponent }
        let candidate = suggested ?? url.lastPathComponent
        if !URL(filePath: candidate).pathExtension.isEmpty { return candidate }
        let fileExtension: String
        switch response.mimeType?.lowercased() {
        case "image/png": fileExtension = "png"
        case "image/gif": fileExtension = "gif"
        case "image/webp": fileExtension = "webp"
        case "image/heic": fileExtension = "heic"
        case "image/heif": fileExtension = "heif"
        default: fileExtension = "jpg"
        }
        return "\(candidate.isEmpty ? "attachment" : candidate).\(fileExtension)"
    }
}

private extension LuxJSONValue {
    init?(any: Any) {
        switch any {
        case let value as String: self = .string(value)
        case let value as Bool: self = .bool(value)
        case let value as NSNumber: self = .number(value.doubleValue)
        case let value as [String: Any]:
            self = .object(value.compactMapValues(LuxJSONValue.init(any:)))
        case let value as [Any]:
            self = .array(value.compactMap(LuxJSONValue.init(any:)))
        case is NSNull: self = .null
        default: return nil
        }
    }
}
