import Foundation

public protocol LuxTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public struct URLSessionLuxTransport: LuxTransport {
    /// Default request inactivity and complete-resource deadlines. Supply your
    /// own URLSession when an application needs different transport settings.
    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()

    private let session: URLSession

    public init(session: URLSession = Self.defaultSession) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}
