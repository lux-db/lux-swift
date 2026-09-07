import Foundation
import Testing
@testable import Lux

struct LuxTransportTests {
    @Test func defaultSessionHasRequestAndResourceDeadlines() {
        let configuration = URLSessionLuxTransport.defaultSession.configuration
        #expect(configuration.timeoutIntervalForRequest == 30)
        #expect(configuration.timeoutIntervalForResource == 60)
    }

    @Test func cancellationStopsAURLSessionRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PendingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = try LuxClient(url: "https://example.test", publishableKey: "public", session: session)
        let request = Task { try await client.appleSignInNonce() }
        try await Task.sleep(for: .milliseconds(20))
        request.cancel()
        do {
            _ = try await request.value
            Issue.record("Cancelled request unexpectedly succeeded")
        } catch is CancellationError {
        } catch let error as URLError {
            #expect(error.code == .cancelled)
        }
    }
}

private final class PendingURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}
