import Foundation
import Observation
import UserNotifications

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

public enum LuxAPNSEnvironment: String, Codable, Sendable, Equatable {
    case sandbox
    case production
    case unspecified = ""
}

public enum LuxPushAuthorizationStatus: Sendable, Equatable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
}

public struct LuxPushAuthorizationOptions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let alert = Self(rawValue: 1 << 0)
    public static let badge = Self(rawValue: 1 << 1)
    public static let sound = Self(rawValue: 1 << 2)
    public static let provisional = Self(rawValue: 1 << 3)
    public static let criticalAlert = Self(rawValue: 1 << 4)
    public static let standard: Self = [.alert, .badge, .sound]

    var native: UNAuthorizationOptions {
        var options: UNAuthorizationOptions = []
        if contains(.alert) { options.insert(.alert) }
        if contains(.badge) { options.insert(.badge) }
        if contains(.sound) { options.insert(.sound) }
        if contains(.provisional) { options.insert(.provisional) }
        if contains(.criticalAlert) { options.insert(.criticalAlert) }
        return options
    }
}

@MainActor
public protocol LuxPushSystemProviding: AnyObject {
    func authorizationStatus() async -> LuxPushAuthorizationStatus
    func requestAuthorization(options: LuxPushAuthorizationOptions) async throws -> Bool
    func registerForRemoteNotifications()
}

@MainActor
public final class SystemLuxPushProvider: LuxPushSystemProviding {
    public init() {}

    public func authorizationStatus() async -> LuxPushAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let status: LuxPushAuthorizationStatus = switch settings.authorizationStatus {
                case .notDetermined: .notDetermined
                case .denied: .denied
                case .authorized: .authorized
                case .provisional: .provisional
                case .ephemeral: .ephemeral
                @unknown default: .notDetermined
                }
                continuation.resume(returning: status)
            }
        }
    }

    public func requestAuthorization(options: LuxPushAuthorizationOptions) async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: options.native)
    }

    public func registerForRemoteNotifications() {
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #elseif os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
        #endif
    }
}

public protocol LuxAPNSEnvironmentProviding: Sendable {
    func environment() -> LuxAPNSEnvironment
}

public struct SystemLuxAPNSEnvironmentProvider: LuxAPNSEnvironmentProviding {
    public init() {}

    public func environment() -> LuxAPNSEnvironment {
        // iOS does not expose a public API for reading the current process's
        // code-signing entitlements. Teams with custom configurations can set
        // `LuxAPNSEnvironment` to `sandbox` or `production` in Info.plist. The
        // standard Xcode split is development/simulator -> sandbox and Release
        // (including TestFlight/App Store) -> production.
        if let configured = Bundle.main.object(forInfoDictionaryKey: "LuxAPNSEnvironment") as? String {
            switch configured.lowercased() {
            case "sandbox", "development": return .sandbox
            case "production": return .production
            default: return .unspecified
            }
        }
        #if targetEnvironment(simulator)
        return .sandbox
        #elseif DEBUG
        return .sandbox
        #else
        return .production
        #endif
    }
}

public struct LuxPushDevice: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let platform: String
    public let appID: String
    public let environment: LuxAPNSEnvironment?
    public let createdAt: String
    public let lastSeenAt: String

    enum CodingKeys: String, CodingKey {
        case id, platform, environment
        case appID = "app_id"
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
    }
}

/// Auth-bound APNs registration for one Lux project.
@MainActor
@Observable
public final class LuxPush {
    public private(set) var authorizationStatus: LuxPushAuthorizationStatus = .notDetermined
    public private(set) var registration: LuxStoredPushRegistration?
    public private(set) var isSynchronizing = false
    public var isRegistered: Bool { registration?.deviceID != nil }

    private let client: LuxClient
    private let auth: LuxAuth
    private let store: any LuxPushRegistrationStore
    private let system: any LuxPushSystemProviding
    private let environmentProvider: any LuxAPNSEnvironmentProviding
    private var registrationGeneration: UInt64 = 0
    @ObservationIgnored
    private nonisolated(unsafe) var synchronizationTask: Task<Void, Error>?
    private var synchronizationTaskGeneration: UInt64?
    @ObservationIgnored
    private nonisolated(unsafe) var authEventsTask: Task<Void, Never>?
    private var preSignOutHandlerID: UUID?
    private var isSigningOut = false

    public convenience init(client: LuxClient, auth: LuxAuth) {
        self.init(
            client: client,
            auth: auth,
            store: KeychainLuxPushRegistrationStore(account: client.baseURL.absoluteString),
            system: SystemLuxPushProvider(),
            environmentProvider: SystemLuxAPNSEnvironmentProvider()
        )
    }

    public init(
        client: LuxClient,
        auth: LuxAuth,
        store: any LuxPushRegistrationStore,
        system: any LuxPushSystemProviding,
        environmentProvider: any LuxAPNSEnvironmentProviding
    ) {
        self.client = client
        self.auth = auth
        self.store = store
        self.system = system
        self.environmentProvider = environmentProvider
        self.registration = try? store.load()
        installAuthLifecycleSynchronization()
    }

    init(
        client: LuxClient,
        auth: LuxAuth,
        store: any LuxPushRegistrationStore,
        system: any LuxPushSystemProviding,
        environmentProvider: any LuxAPNSEnvironmentProviding,
        automaticallySynchronizesAuthEvents: Bool
    ) {
        self.client = client
        self.auth = auth
        self.store = store
        self.system = system
        self.environmentProvider = environmentProvider
        self.registration = try? store.load()
        if automaticallySynchronizesAuthEvents {
            installAuthLifecycleSynchronization()
        } else {
            installPreSignOutHandler()
        }
    }

    private func installAuthLifecycleSynchronization() {
        installPreSignOutHandler()
        let auth = self.auth
        self.authEventsTask = Task { @MainActor [weak self, auth] in
            for await event in auth.events() {
                guard let self else { return }
                switch event {
                case .initialSession(let session):
                    if session != nil { try? await self.synchronize() }
                case .signedIn, .tokenRefreshed:
                    try? await self.synchronize()
                case .signedOut:
                    try? self.markPending()
                case .userUpdated:
                    break
                }
            }
        }
    }

    private func installPreSignOutHandler() {
        self.preSignOutHandlerID = auth.addPreSignOutHandler { [weak self] session in
            try await self?.unregisterForSignOut(accessToken: session.accessToken)
        }
    }

    deinit {
        authEventsTask?.cancel()
        synchronizationTask?.cancel()
    }

    @discardableResult
    public func refreshAuthorizationStatus() async -> LuxPushAuthorizationStatus {
        let status = await system.authorizationStatus()
        authorizationStatus = status
        return status
    }

    /// Request notification permission and ask the OS to mint an APNs token.
    /// Forward the resulting application-delegate callback to
    /// ``register(deviceToken:appID:)``.
    @discardableResult
    public func requestAuthorization(
        _ options: LuxPushAuthorizationOptions = .standard,
        registerWithSystem: Bool = true
    ) async throws -> LuxPushAuthorizationStatus {
        _ = try await system.requestAuthorization(options: options)
        let status = await refreshAuthorizationStatus()
        if registerWithSystem, status != .denied, status != .notDetermined {
            system.registerForRemoteNotifications()
        }
        return status
    }

    /// Persist the APNs token immediately. If no user is signed in it remains
    /// pending and is registered automatically after the next authentication.
    public func register(deviceToken: Data, appID: String = "default") async throws {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        try await register(
            token: token,
            environment: environmentProvider.environment(),
            appID: appID
        )
    }

    public func register(
        token: String,
        environment: LuxAPNSEnvironment = .unspecified,
        appID: String = "default"
    ) async throws {
        guard !token.isEmpty else {
            throw LuxError(code: "PUSH_EMPTY_TOKEN", message: "APNs returned an empty device token")
        }
        let existing = registration
        let sameToken = existing?.token == token
        var pendingRemovalTokens = existing?.pendingRemovalTokens ?? []
        if let existing, !sameToken {
            pendingRemovalTokens.append(existing.token)
            pendingRemovalTokens = Array(Set(pendingRemovalTokens)).sorted()
        }
        let pending = LuxStoredPushRegistration(
            token: token,
            environment: environment,
            appID: appID,
            deviceID: sameToken ? existing?.deviceID : nil,
            userID: sameToken ? existing?.userID : nil,
            pendingRemovalTokens: pendingRemovalTokens
        )
        try store.save(pending)
        replaceRegistration(pending)
        let generation = registrationGeneration
        if auth.isAuthenticated, !isSigningOut {
            try await synchronize(expectedGeneration: generation)
        }
    }

    /// Register the stored token to the current Lux user. This is idempotent and
    /// never accepts a caller-supplied user id; the engine derives auth.uid().
    public func synchronize() async throws {
        try await synchronize(expectedGeneration: registrationGeneration)
    }

    private func synchronize(expectedGeneration: UInt64) async throws {
        guard !isSigningOut else { throw CancellationError() }
        if let synchronizationTask,
           synchronizationTaskGeneration == expectedGeneration {
            return try await synchronizationTask.value
        }
        synchronizationTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.performSynchronization(expectedGeneration: expectedGeneration)
        }
        synchronizationTask = task
        synchronizationTaskGeneration = expectedGeneration
        do {
            try await task.value
            if synchronizationTaskGeneration == expectedGeneration {
                synchronizationTask = nil
                synchronizationTaskGeneration = nil
            }
        } catch {
            if synchronizationTaskGeneration == expectedGeneration {
                synchronizationTask = nil
                synchronizationTaskGeneration = nil
            }
            throw error
        }
    }

    private func performSynchronization(expectedGeneration: UInt64) async throws {
        guard let pending = registration else { return }
        guard let user = auth.user else { return }
        try checkRegistration(expectedGeneration, matches: pending, userID: user.id)
        isSynchronizing = true
        defer { isSynchronizing = false }
        let accessToken = try await auth.accessToken()
        try checkRegistration(expectedGeneration, matches: pending, userID: user.id)
        let response: RegisterDeviceResponse = try await client.request(
            .post,
            path: "/push/devices",
            body: RegisterDeviceBody(
                token: pending.token,
                platform: "ios",
                appID: pending.appID,
                environment: pending.environment.rawValue
            ),
            bearerToken: accessToken
        )
        try checkRegistration(expectedGeneration, matches: pending, userID: user.id)
        let registered = LuxStoredPushRegistration(
            token: pending.token,
            environment: pending.environment,
            appID: pending.appID,
            deviceID: response.id,
            userID: user.id,
            pendingRemovalTokens: []
        )
        for token in pending.pendingRemovalTokens ?? [] {
            try checkRegistration(expectedGeneration, matches: pending, userID: user.id)
            try await deleteDevice(token: token, accessToken: accessToken)
        }
        try checkRegistration(expectedGeneration, matches: pending, userID: user.id)
        try store.save(registered)
        try checkRegistration(expectedGeneration, matches: pending, userID: user.id)
        replaceRegistration(registered)
    }

    public func devices() async throws -> [LuxPushDevice] {
        let token = try await auth.accessToken()
        let response: DevicesResponse = try await client.request(
            .get,
            path: "/push/devices",
            bearerToken: token
        )
        return response.devices
    }

    /// Unregister delivery but retain the APNs token so a future signed-in user
    /// can opt back in without waiting for Apple to rotate it.
    public func unregister() async throws {
        if let synchronizationTask {
            _ = try? await synchronizationTask.value
        }
        guard let current = registration else { return }
        let generation = registrationGeneration
        let userID = auth.user?.id
        let token = try await auth.accessToken()
        try checkRegistration(generation, matches: current, userID: userID)
        try await deleteDevice(token: current.token, accessToken: token)
        for staleToken in current.pendingRemovalTokens ?? [] {
            try checkRegistration(generation, matches: current, userID: userID)
            try await deleteDevice(token: staleToken, accessToken: token)
        }
        try checkRegistration(generation, matches: current, userID: userID)
        try markPending(expectedGeneration: generation)
    }

    /// Unregister and forget the local APNs token entirely.
    public func disable() async throws {
        if registration != nil, auth.isAuthenticated { try await unregister() }
        try store.clear()
        replaceRegistration(nil)
    }

    private func unregisterForSignOut(accessToken: String) async throws {
        isSigningOut = true
        defer { isSigningOut = false }
        if let synchronizationTask {
            _ = try? await synchronizationTask.value
        }
        guard let current = registration else { return }
        let generation = registrationGeneration
        var firstError: Error?
        let tokens = Array(Set([current.token] + (current.pendingRemovalTokens ?? []))).sorted()
        for token in tokens {
            do { try await deleteDevice(token: token, accessToken: accessToken) }
            catch { if firstError == nil { firstError = error } }
        }
        do {
            guard registrationGeneration == generation, registration == current else { return }
            try markPending(expectedGeneration: generation)
        } catch {
            // Preserve the token but remove the stale local ownership. A future
            // login re-registers it, and the engine atomically re-points it.
            if registrationGeneration == generation, registration == current {
                try? markPending(expectedGeneration: generation)
            }
            if firstError == nil { firstError = error }
        }
        if let firstError { throw firstError }
    }

    private func deleteDevice(token: String, accessToken: String) async throws {
        let _: DeleteDeviceResponse = try await client.request(
            .delete,
            path: "/push/devices",
            body: DeleteDeviceBody(token: token),
            bearerToken: accessToken
        )
    }

    private func markPending(expectedGeneration: UInt64? = nil) throws {
        guard let current = registration else { return }
        if let expectedGeneration, expectedGeneration != registrationGeneration {
            throw CancellationError()
        }
        let pending = LuxStoredPushRegistration(
            token: current.token,
            environment: current.environment,
            appID: current.appID,
            deviceID: nil,
            userID: nil,
            pendingRemovalTokens: []
        )
        try store.save(pending)
        replaceRegistration(pending)
    }

    private func replaceRegistration(_ registration: LuxStoredPushRegistration?) {
        self.registration = registration
        registrationGeneration &+= 1
    }

    private func checkRegistration(
        _ generation: UInt64,
        matches expected: LuxStoredPushRegistration,
        userID: String?
    ) throws {
        guard
            !isSigningOut,
            registrationGeneration == generation,
            registration == expected,
            auth.user?.id == userID
        else { throw CancellationError() }
    }
}

private struct RegisterDeviceBody: Encodable {
    let token: String
    let platform: String
    let appID: String
    let environment: String
    enum CodingKeys: String, CodingKey {
        case token, platform, environment
        case appID = "app_id"
    }
}

private struct RegisterDeviceResponse: Decodable { let id: String }
private struct DevicesResponse: Decodable { let devices: [LuxPushDevice] }
private struct DeleteDeviceBody: Encodable { let token: String }
private struct DeleteDeviceResponse: Decodable { let deleted: Bool }
