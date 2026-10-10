import Foundation
import HearthAPI
import HearthModel
import OSLog
import Security
import Synchronization

/// Stores imported client certificates (.p12 + passphrase) per connection in the Keychain and supplies
/// them to HearthAPI through `APIClientFactory.clientIdentityProvider` (mutual TLS).
///
/// NOTE: lives in the app until HearthData offers a client-certificate API; then this can forward to it.
enum ClientIdentityStore {
    private static let service = (Bundle.main.bundleIdentifier ?? "dev.hearth.hearth") + ".client-identity"
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hearth", category: "ClientIdentityStore")

    private struct Stored: Codable {
        var p12: Data
        var passphrase: String
    }

    /// Decoded identities (persisted ones are loaded lazily) and provisional ones used while adding a server.
    private static let cache = Mutex<[ConnectionID: SecIdentityBox]>([:])

    private final class SecIdentityBox: @unchecked Sendable {
        let identity: SecIdentity?
        init(_ identity: SecIdentity?) { self.identity = identity }
    }

    /// Installs the provider. Call once at launch.
    static func install() {
        APIClientFactory.clientIdentityProvider = { connectionID in
            identity(for: connectionID)
        }
    }

    static func identity(for connectionID: ConnectionID) -> SecIdentity? {
        if let cached = cache.withLock({ $0[connectionID] }) {
            return cached.identity
        }
        let identity = load(connectionID).flatMap { decode($0.p12, passphrase: $0.passphrase) }
        cache.withLock { $0[connectionID] = SecIdentityBox(identity) }
        return identity
    }

    /// Makes an identity available for requests made while adding a connection to `host`.
    static func setProvisional(_ p12: Data?, passphrase: String, host: URL) {
        let id = APIClientFactory.provisionalConnectionID(for: host)
        let identity = p12.flatMap { decode($0, passphrase: passphrase) }
        cache.withLock { $0[id] = SecIdentityBox(identity) }
    }

    /// Persists an identity for a connection (or removes it when `p12` is nil).
    static func save(_ p12: Data?, passphrase: String, for connectionID: ConnectionID) {
        delete(connectionID)
        guard let p12 else { return }
        guard let data = try? JSONEncoder().encode(Stored(p12: p12, passphrase: passphrase)) else { return }
        var query = baseQuery(connectionID)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("Storing client identity failed: \(status)")
        }
        cache.withLock { $0[connectionID] = SecIdentityBox(decode(p12, passphrase: passphrase)) }
    }

    static func delete(_ connectionID: ConnectionID) {
        SecItemDelete(baseQuery(connectionID) as CFDictionary)
        _ = cache.withLock { $0.removeValue(forKey: connectionID) }
    }

    static func hasIdentity(for connectionID: ConnectionID) -> Bool {
        identity(for: connectionID) != nil
    }

    /// Decodes a .p12 file. Returns nil when the passphrase is wrong.
    static func decode(_ p12: Data, passphrase: String) -> SecIdentity? {
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: passphrase] as CFDictionary
        guard SecPKCS12Import(p12 as CFData, options, &items) == errSecSuccess,
              let array = items as? [[String: Any]],
              let first = array.first,
              let value = first[kSecImportItemIdentity as String] else {
            return nil
        }
        // `kSecImportItemIdentity` is always a SecIdentity.
        return (value as! SecIdentity)
    }

    private static func baseQuery(_ connectionID: ConnectionID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectionID,
        ]
    }

    private static func load(_ connectionID: ConnectionID) -> Stored? {
        var query = baseQuery(connectionID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }
}
