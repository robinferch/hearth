import Foundation
import HearthModel
import Security
import Synchronization

/// Supplies TLS client identities (mTLS) for connections. Configured through `APIClientFactory.clientIdentityProvider`.
enum ClientIdentityProvider {
    typealias Provider = @Sendable (ConnectionID) -> SecIdentity?

    private static let storage = Mutex<Provider?>(nil)

    static var provider: Provider? {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }

    static func credential(for connectionID: ConnectionID) -> URLCredential? {
        guard let identity = provider?(connectionID) else {
            return nil
        }
        return URLCredential(identity: identity, certificates: nil, persistence: .forSession)
    }
}

public extension APIClientFactory {
    /// Returns the client certificate identity (imported `.p12`) for a connection, or `nil` when none is configured.
    ///
    /// Called whenever a server requests a client certificate. Requests made while adding a connection
    /// (status, login, OpenID) use `provisionalConnectionID(for:)` because no connection exists yet.
    static var clientIdentityProvider: (@Sendable (ConnectionID) -> SecIdentity?)? {
        get { ClientIdentityProvider.provider }
        set { ClientIdentityProvider.provider = newValue }
    }

    /// Identifier passed to `clientIdentityProvider` for unauthenticated requests against `host`.
    static func provisionalConnectionID(for host: URL) -> ConnectionID {
        "provisional:" + host.absoluteString
    }
}
