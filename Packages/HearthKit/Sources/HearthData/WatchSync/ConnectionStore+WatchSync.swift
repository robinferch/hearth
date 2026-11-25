import CryptoKit
import Foundation
import HearthAPI
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
            guard let local, local != entry.tokens else { continue }
            let isUnauthorized = status[id] == .unauthorized || connectionNeedingReauthorization == id
            // The server's issue time decides which pair is current; the ledger's device clocks are the fallback.
            let isNewer = entry.tokens.isNewer(than: local)
                ?? (entry.tokensChangedAt > WatchTokenLedger.changedAt(id, defaults: defaults) ?? .distantPast)
            guard isNewer || isUnauthorized else { continue }
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

// MARK: - Shared session

extension ConnectionStore {
    /// `TokenStore.externalTokens` for the API clients: tokens of the same session on the paired device, when they
    /// are newer than `current` (or `current` was rejected). Adopted tokens are stored before they are returned.
    func pairedDeviceTokens(for id: ConnectionID, current: AuthTokens, reason: ExternalTokenReason) async -> AuthTokens? {
        guard connection(id) != nil else { return nil }
        if let local = adoptableTokens(environment.tokenStore.cachedOrStoredTokens(for: id), current: current, reason: reason) {
            // Arrived from the paired device meanwhile.
            return local
        }
        guard let pairedDeviceCredentials else { return nil }
        let entry = await pairedDeviceCredentials(reason)?.entries.first { $0.connection.id == id }
        // Credentials transferred while waiting (e.g. delivered right after the session activated) are in the store:
        // use them instead of the reply when the reply is no better.
        var best = entry?.tokens
        if let stored = environment.tokenStore.cachedOrStoredTokens(for: id), stored != current,
           best.map({ $0 == current || stored.isNewer(than: $0) == true }) ?? true {
            best = stored
        }
        guard let tokens = adoptableTokens(best, current: current, reason: reason) else { return nil }
        if let entry, tokens == entry.tokens, environment.tokenStore.cachedOrStoredTokens(for: id) != tokens {
            WatchTokenLedger.record(id, fingerprint: WatchTokenLedger.fingerprint(tokens), changedAt: entry.tokensChangedAt, defaults: environment.defaults)
            environment.tokenStore.set(tokens, for: id)
        }
        Logger(category: "WatchSync").info("Using the paired device's tokens for \(id, privacy: .public) (\(String(describing: reason), privacy: .public))")
        return tokens
    }

    /// `candidate` if it should replace `current`: before a refresh only when it's provably newer (adopting an older
    /// pair would discard the only valid refresh token), after a rejection whenever it differs.
    private func adoptableTokens(_ candidate: AuthTokens?, current: AuthTokens, reason: ExternalTokenReason) -> AuthTokens? {
        guard let candidate, candidate != current, candidate.refreshToken != nil else { return nil }
        switch reason {
        case .aboutToRefresh:
            return candidate.isNewer(than: current) == true ? candidate : nil
        case .refreshRejected:
            return candidate.refreshToken != current.refreshToken ? candidate : nil
        }
    }

    /// Refreshes access tokens that expire soon (bounded by `timeout`), so credentials handed to the paired device
    /// stay usable for a while and it doesn't rotate the shared refresh token itself.
    public func refreshTokensForPairedDevice(timeout: Duration = .seconds(8)) async {
        guard !isOffline else { return }
        let clients = signedInConnections.compactMap { try? client(for: $0.id) }
        guard !clients.isEmpty else { return }
        // Returns after `timeout` at the latest; a refresh still running then completes (and stores) on its own.
        let (done, finish) = AsyncStream<Never>.makeStream()
        Task {
            await withTaskGroup(of: Void.self) { group in
                for client in clients {
                    group.addTask { await client.refreshAccessTokenIfNeeded() }
                }
            }
            finish.finish()
        }
        Task {
            try? await Task.sleep(for: timeout)
            finish.finish()
        }
        for await _ in done {}
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
