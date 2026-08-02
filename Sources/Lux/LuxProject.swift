import AuthenticationServices
import Foundation
import Observation

/// One configured Lux project. The 1.1 mobile surface intentionally contains
/// only authentication and push notification registration.
@MainActor
@Observable
public final class LuxProject {
    public let client: LuxClient
    public let auth: LuxAuth
    public let push: LuxPush

    public init(
        url: String,
        publishableKey: String,
        networkPolicy: LuxNetworkPolicy = .secure,
        session: URLSession = .shared,
        presentationAnchor: @escaping () -> ASPresentationAnchor? = { nil }
    ) throws {
        let client = try LuxClient(
            url: url,
            publishableKey: publishableKey,
            networkPolicy: networkPolicy,
            session: session
        )
        let auth = LuxAuth(client: client, presentationAnchor: presentationAnchor)
        self.client = client
        self.auth = auth
        self.push = LuxPush(client: client, auth: auth)
    }
}
