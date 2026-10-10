import Foundation
import HearthAPI
import HearthModel
import Synchronization

/// Storage for connection records, tokens and client certificates.
protocol CredentialStoring: Sendable {
    func loadConnections() -> [Connection]
    func saveConnection(_ connection: Connection)
    func deleteConnection(_ id: ConnectionID)

    func tokens(for id: ConnectionID) -> AuthTokens?
    func saveTokens(_ tokens: AuthTokens, for id: ConnectionID)
    func deleteTokens(for id: ConnectionID)

    /// PKCS#12 blob + passphrase, keyed by `ClientIdentityKey`.
    func clientCertificate(for key: String) -> ClientCertificate?
    func saveClientCertificate(_ certificate: ClientCertificate, for key: String)
    func deleteClientCertificate(for key: String)
}

struct ClientCertificate: Codable, Sendable, Hashable {
    var pkcs12: Data
    var passphrase: String
}

/// Production implementation backed by the Keychain.
///
/// - Connection records are synchronizable (iCloud Keychain) so they show up on other devices and the watch.
/// - Tokens are device-only.
struct KeychainCredentialStore: CredentialStoring {
    private let keychain: Keychain

    init(keychain: Keychain = Keychain()) {
        self.keychain = keychain
    }

    private enum Prefix {
        static let connection = "connection:"
        static let tokens = "tokens:"
        static let certificate = "certificate:"
    }

    func loadConnections() -> [Connection] {
        keychain.items(prefix: Prefix.connection)
            .compactMap { try? JSONDecoder().decode(Connection.self, from: $0.data) }
            .sorted { $0.addedAt < $1.addedAt }
    }

    func saveConnection(_ connection: Connection) {
        guard let data = try? JSONEncoder().encode(connection) else { return }
        keychain.set(data, account: Prefix.connection + connection.id, synchronizable: true)
    }

    func deleteConnection(_ id: ConnectionID) {
        keychain.delete(account: Prefix.connection + id)
    }

    func tokens(for id: ConnectionID) -> AuthTokens? {
        keychain.data(account: Prefix.tokens + id).flatMap { try? JSONDecoder().decode(AuthTokens.self, from: $0) }
    }

    func saveTokens(_ tokens: AuthTokens, for id: ConnectionID) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        keychain.set(data, account: Prefix.tokens + id, synchronizable: false)
    }

    func deleteTokens(for id: ConnectionID) {
        keychain.delete(account: Prefix.tokens + id)
    }

    func clientCertificate(for key: String) -> ClientCertificate? {
        keychain.data(account: Prefix.certificate + key).flatMap { try? JSONDecoder().decode(ClientCertificate.self, from: $0) }
    }

    func saveClientCertificate(_ certificate: ClientCertificate, for key: String) {
        guard let data = try? JSONEncoder().encode(certificate) else { return }
        keychain.set(data, account: Prefix.certificate + key, synchronizable: true)
    }

    func deleteClientCertificate(for key: String) {
        keychain.delete(account: Prefix.certificate + key)
    }
}

/// Volatile implementation used by tests and previews.
final class InMemoryCredentialStore: CredentialStoring {
    private struct State {
        var connections: [ConnectionID: Connection] = [:]
        var tokens: [ConnectionID: AuthTokens] = [:]
        var certificates: [String: ClientCertificate] = [:]
    }

    private let state = Mutex(State())

    init(connections: [Connection] = [], tokens: [ConnectionID: AuthTokens] = [:]) {
        state.withLock {
            $0.connections = Dictionary(connections.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            $0.tokens = tokens
        }
    }

    func loadConnections() -> [Connection] { state.withLock { $0.connections.values.sorted { $0.addedAt < $1.addedAt } } }
    func saveConnection(_ connection: Connection) { state.withLock { $0.connections[connection.id] = connection } }
    func deleteConnection(_ id: ConnectionID) { _ = state.withLock { $0.connections.removeValue(forKey: id) } }
    func tokens(for id: ConnectionID) -> AuthTokens? { state.withLock { $0.tokens[id] } }
    func saveTokens(_ tokens: AuthTokens, for id: ConnectionID) { state.withLock { $0.tokens[id] = tokens } }
    func deleteTokens(for id: ConnectionID) { _ = state.withLock { $0.tokens.removeValue(forKey: id) } }
    func clientCertificate(for key: String) -> ClientCertificate? { state.withLock { $0.certificates[key] } }
    func saveClientCertificate(_ certificate: ClientCertificate, for key: String) { state.withLock { $0.certificates[key] = certificate } }
    func deleteClientCertificate(for key: String) { _ = state.withLock { $0.certificates.removeValue(forKey: key) } }
}

/// `TokenStore` handed to HearthAPI clients. Caches tokens in memory to avoid Keychain round trips per request.
final class CredentialTokenStore: TokenStore {
    private let credentials: any CredentialStoring
    private let cache = Mutex<[ConnectionID: AuthTokens]>([:])
    private let onChange: @Sendable (ConnectionID, AuthTokens) -> Void

    init(credentials: any CredentialStoring, onChange: @escaping @Sendable (ConnectionID, AuthTokens) -> Void = { _, _ in }) {
        self.credentials = credentials
        self.onChange = onChange
    }

    func tokens(for connectionID: ConnectionID) async -> AuthTokens? {
        if let cached = cache.withLock({ $0[connectionID] }) {
            return cached
        }
        let tokens = credentials.tokens(for: connectionID)
        if let tokens {
            cache.withLock { $0[connectionID] = tokens }
        }
        return tokens
    }

    func store(_ tokens: AuthTokens, for connectionID: ConnectionID) async {
        set(tokens, for: connectionID)
        onChange(connectionID, tokens)
    }

    /// Synchronous variant used by `ConnectionStore`.
    func set(_ tokens: AuthTokens, for connectionID: ConnectionID) {
        cache.withLock { $0[connectionID] = tokens }
        credentials.saveTokens(tokens, for: connectionID)
    }

    func cachedOrStoredTokens(for connectionID: ConnectionID) -> AuthTokens? {
        if let cached = cache.withLock({ $0[connectionID] }) {
            return cached
        }
        return credentials.tokens(for: connectionID)
    }

    func remove(_ connectionID: ConnectionID) {
        _ = cache.withLock { $0.removeValue(forKey: connectionID) }
        credentials.deleteTokens(for: connectionID)
    }
}
