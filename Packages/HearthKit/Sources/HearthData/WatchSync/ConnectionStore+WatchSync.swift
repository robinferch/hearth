import CryptoKit
import Foundation
import HearthModel
import os

/// Credential sharing between the iPhone and the watch.
///
/// audiobookshelf rotates refresh tokens, so both devices share one token pair: whenever one side refreshes, it sends
/// the new pair to the other (`changedTokenConnections()` + `watchCredentials(for:)`), and a side that becomes
/// unauthorized asks the other one for its tokens. `tokensChangedAt` resolves races (newer wins).
public extension ConnectionStore {
    /// Whether tokens are stored for the connection (connection records can arrive via iCloud Keychain without tokens).
    func hasTokens(for id: ConnectionID) -> Bool {
        environment.tokenStore.cachedOrStoredTokens(for: id) != nil
    }

    /// Connections that have tokens on this device.
    var signedInConnections: [Connection] {
        connections.filter { hasTokens(for: $0.id) }
    }

    /// Connections, tokens and client certificates of this device (all connections when `ids` is `nil`).
    func watchCredentials(for ids: Set<ConnectionID>? = nil) -> WatchCredentials {
        _ = changedTokenConnections()
        let entries = connections.compactMap { connection -> WatchCredentials.Entry? in
            guard ids?.contains(connection.id) ?? true,
                  let tokens = environment.tokenStore.cachedOrStoredTokens(for: connection.id) else { return nil }
            let certificate = environment.credentials.clientCertificate(for: ClientIdentityKey.make(connection.host))
            return WatchCredentials.Entry(
                connection: connection,
                tokens: tokens,
                tokensChangedAt: WatchTokenLedger.changedAt(connection.id, defaults: environment.defaults) ?? .distantPast,
                clientCertificate: certificate?.pkcs12,
                clientCertificatePassphrase: certificate?.passphrase
            )
        }
        return WatchCredentials(entries: entries)
    }

    /// Connections whose tokens changed since the last call (e.g. after a refresh). Records the change time.
    func changedTokenConnections() -> Set<ConnectionID> {
        var changed = Set<ConnectionID>()
        let defaults = environment.defaults
        for connection in connections {
            guard let tokens = environment.tokenStore.cachedOrStoredTokens(for: connection.id) else { continue }
            let fingerprint = WatchTokenLedger.fingerprint(tokens)
            if WatchTokenLedger.fingerprint(connection.id, defaults: defaults) != fingerprint {
                WatchTokenLedger.record(connection.id, fingerprint: fingerprint, changedAt: .now, defaults: defaults)
                changed.insert(connection.id)
            }
        }
        return changed
    }

    /// Applies credentials received from the other device. New connections are added; tokens of existing ones are
    /// replaced when the received ones are newer (or this device has none / is unauthorized).
    ///
    /// - Returns: the connections that were added or updated.
    @discardableResult
    func applyWatchCredentials(_ credentials: WatchCredentials) async -> [ConnectionID] {
        let logger = Logger(category: "WatchSync")
        let defaults = environment.defaults
        var applied: [ConnectionID] = []

        for entry in credentials.entries {
            let id = entry.connection.id
            if let certificate = entry.clientCertificate, let passphrase = entry.clientCertificatePassphrase, !hasClientCertificate(for: entry.connection.host) {
                do {
                    try importClientCertificate(certificate, passphrase: passphrase, for: entry.connection.host)
                } catch {
                    logger.error("Importing the client certificate of \(entry.connection.displayName, privacy: .private) failed")
                }
            }

            let fingerprint = WatchTokenLedger.fingerprint(entry.tokens)
            let local = environment.tokenStore.cachedOrStoredTokens(for: id)
            if connection(id) == nil || local == nil {
                WatchTokenLedger.record(id, fingerprint: fingerprint, changedAt: entry.tokensChangedAt, defaults: defaults)
                await add(entry.connection, tokens: entry.tokens)
                applied.append(id)
                continue
            }
            guard local != entry.tokens else { continue }
            let localChange = WatchTokenLedger.changedAt(id, defaults: defaults) ?? .distantPast
            let isUnauthorized = status[id] == .unauthorized || connectionNeedingReauthorization == id
            guard entry.tokensChangedAt > localChange || isUnauthorized else { continue }
            WatchTokenLedger.record(id, fingerprint: fingerprint, changedAt: entry.tokensChangedAt, defaults: defaults)
            if let existing = connection(id), existing.headers != entry.connection.headers || existing.pinnedCertificateSHA256 != entry.connection.pinnedCertificateSHA256 {
                var updated = existing
                updated.headers = entry.connection.headers
                updated.pinnedCertificateSHA256 = entry.connection.pinnedCertificateSHA256
                updated.serverVersion = entry.connection.serverVersion ?? existing.serverVersion
                await update(updated)
            }
            await updateTokens(entry.tokens, for: id)
            applied.append(id)
        }
        if !applied.isEmpty {
            logger.info("Applied credentials of \(applied.count) connection(s) from the paired device")
        }
        return applied
    }
}

/// Remembers a fingerprint of each connection's tokens and when they last changed (app group defaults).
enum WatchTokenLedger {
    private static let prefix = "watchSync.tokens."

    static func fingerprint(_ tokens: AuthTokens) -> String {
        let digest = SHA256.hash(data: Data("\(tokens.accessToken)|\(tokens.refreshToken ?? "")".utf8))
        return Data(digest).base64EncodedString()
    }

    static func fingerprint(_ id: ConnectionID, defaults: UserDefaults) -> String? {
        (defaults.dictionary(forKey: prefix + id)?["fingerprint"]) as? String
    }

    static func changedAt(_ id: ConnectionID, defaults: UserDefaults) -> Date? {
        (defaults.dictionary(forKey: prefix + id)?["changedAt"]) as? Date
    }

    static func record(_ id: ConnectionID, fingerprint: String, changedAt: Date, defaults: UserDefaults) {
        defaults.set(["fingerprint": fingerprint, "changedAt": changedAt], forKey: prefix + id)
    }
}
