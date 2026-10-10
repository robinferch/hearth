import Foundation
import HearthAPI
import HearthModel
import Observation
import os

/// Relays `APIClientDelegate` callbacks to the connection store without exposing the conformance publicly.
final class UnauthorizedRelay: APIClientDelegate {
    private let handler: @Sendable (ConnectionID) async -> Void

    init(handler: @escaping @Sendable (ConnectionID) async -> Void) {
        self.handler = handler
    }

    func apiClientDidBecomeUnauthorized(_ connectionID: ConnectionID) async {
        await handler(connectionID)
    }
}

/// Connections (Keychain), their API clients, libraries and reachability, plus global offline mode.
@MainActor
@Observable
public final class ConnectionStore {
    public internal(set) var isLoaded = false
    public internal(set) var connections: [Connection] = []
    public internal(set) var libraries: [ConnectionID: [Library]] = [:]
    public internal(set) var status: [ConnectionID: ConnectionStatus] = [:]
    public internal(set) var knownServers: [KnownServer] = []

    /// Global offline mode (user toggle or automatic when no server is reachable).
    public var isOffline = false {
        didSet {
            guard oldValue != isOffline else { return }
            APINetworkPolicy.shared.isOffline = isOffline
            if isOffline {
                if offlineReason == nil {
                    offlineReason = .user
                }
            } else {
                offlineReason = nil
            }
            hearth?.offlineModeChanged()
        }
    }

    /// Why offline mode is active (`nil` while online).
    public internal(set) var offlineReason: OfflineReason?

    /// Whether the device currently has a usable network path.
    public internal(set) var isNetworkAvailable = true
    /// Whether the current path is cellular / personal hotspot.
    public internal(set) var isExpensiveNetwork = false

    /// The connection that needs re-authentication (UI presents a sheet), if any.
    public var connectionNeedingReauthorization: ConnectionID?

    @ObservationIgnored let environment: DataEnvironment
    @ObservationIgnored weak var hearth: HearthData?
    @ObservationIgnored private var clients: [ConnectionID: any AudiobookshelfClient] = [:]
    @ObservationIgnored private var relay: UnauthorizedRelay?
    @ObservationIgnored private var monitor: NetworkMonitor?
    @ObservationIgnored private let logger = Logger(category: "ConnectionStore")

    private var librariesCacheURL: URL { environment.supportURL.appending(path: "libraries.json") }

    init(environment: DataEnvironment) {
        self.environment = environment
        relay = UnauthorizedRelay { [weak self] id in
            await self?.markUnauthorized(id)
        }
        load()
    }

    // MARK: Loading

    /// Loads connection records and cached libraries. Cheap; runs at init and again on demand.
    func load() {
        connections = environment.credentials.loadConnections()
        if let cached = JSON.decode([ConnectionID: [Library]].self, from: try? Data(contentsOf: librariesCacheURL)) {
            libraries = cached.filter { id, _ in connections.contains { $0.id == id } }
        }
        for connection in connections where status[connection.id] == nil {
            status[connection.id] = .loading
        }
        environment.trust.update(connections: connections, credentials: environment.credentials)
        isLoaded = true
        Task {
            knownServers = await environment.store.perform { $0.knownServers() }
        }
    }

    func startMonitoring() {
        guard environment.isLive, monitor == nil else { return }
        let monitor = NetworkMonitor()
        monitor.start { [weak self] state in
            self?.handle(state)
        }
        self.monitor = monitor
    }

    func handle(_ state: NetworkState) {
        let wasAvailable = isNetworkAvailable
        isNetworkAvailable = state.isSatisfied
        isExpensiveNetwork = state.isExpensive

        if !state.isSatisfied {
            guard offlineReason != .user, !connections.isEmpty else { return }
            logger.info("Network unavailable, entering offline mode")
            offlineReason = .noNetwork
            isOffline = true
        } else if !wasAvailable {
            logger.info("Network available again")
            Task {
                if offlineReason == .noNetwork || offlineReason == .unreachable {
                    await retryOffline()
                } else if !isOffline {
                    await hearth?.refresh()
                }
            }
        }
    }

    // MARK: Lookup

    /// All libraries of all connections, ordered by connection then display order.
    public var allLibraries: [Library] { connections.flatMap { libraries[$0.id] ?? [] } }

    public func library(_ id: LibraryIdentifier) -> Library? {
        libraries[id.connectionID]?.first { $0.id == id }
    }

    public func connection(_ id: ConnectionID) -> Connection? {
        connections.first { $0.id == id }
    }

    public func client(for id: ConnectionID) throws -> any AudiobookshelfClient {
        if let client = clients[id] {
            return client
        }
        guard let connection = connection(id) else {
            throw APIError.notFound
        }
        let client = environment.clientFactory(connection, environment.tokenStore, relay)
        clients[id] = client
        return client
    }

    /// Clients of connections that are currently usable (not offline, not unauthorized).
    func availableClients() -> [any AudiobookshelfClient] {
        guard !isOffline else { return [] }
        return connections
            .filter { status[$0.id] != .unauthorized && status[$0.id] != .offline }
            .compactMap { try? client(for: $0.id) }
    }

    func isAvailable(_ id: ConnectionID) -> Bool {
        !isOffline && connection(id) != nil && status[id] != .unauthorized && status[id] != .offline
    }

    // MARK: Mutations

    public func add(_ connection: Connection, tokens: AuthTokens) async {
        environment.tokenStore.set(tokens, for: connection.id)
        environment.credentials.saveConnection(connection)
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = connection
        } else {
            connections.append(connection)
        }
        await replaceClient(for: connection)
        if connectionNeedingReauthorization == connection.id {
            connectionNeedingReauthorization = nil
        }
        let server = KnownServer(host: connection.host, username: connection.username)
        await environment.store.perform { $0.addKnownServer(server) }
        knownServers = await environment.store.perform { $0.knownServers() }

        if isOffline, offlineReason != .user {
            isOffline = false
        }
        await reloadLibraries(only: [connection.id])
        await hearth?.connectionBecameAvailable(connection.id)
    }

    public func update(_ connection: Connection) async {
        guard let index = connections.firstIndex(where: { $0.id == connection.id }) else {
            if let tokens = environment.tokenStore.cachedOrStoredTokens(for: connection.id) {
                await add(connection, tokens: tokens)
            }
            return
        }
        connections[index] = connection
        environment.credentials.saveConnection(connection)
        await replaceClient(for: connection)
        await reloadLibraries(only: [connection.id])
    }

    public func updateTokens(_ tokens: AuthTokens, for id: ConnectionID) async {
        environment.tokenStore.set(tokens, for: id)
        if connectionNeedingReauthorization == id {
            connectionNeedingReauthorization = nil
        }
        guard let connection = connection(id) else { return }
        await replaceClient(for: connection)
        await reloadLibraries(only: [id])
        await hearth?.connectionBecameAvailable(id)
    }

    public func remove(_ id: ConnectionID) async {
        guard let connection = connection(id) else { return }
        if let client = clients.removeValue(forKey: id) {
            await client.disconnectSocket()
        }
        hearth?.stopLiveUpdates(for: id)
        await hearth?.purgeConnection(id)

        environment.tokenStore.remove(id)
        environment.credentials.deleteConnection(id)
        let hostKey = ClientIdentityKey.make(connection.host)
        if !connections.contains(where: { $0.id != id && ClientIdentityKey.make($0.host) == hostKey }) {
            environment.credentials.deleteClientCertificate(for: hostKey)
        }

        connections.removeAll { $0.id == id }
        libraries[id] = nil
        status[id] = nil
        if connectionNeedingReauthorization == id {
            connectionNeedingReauthorization = nil
        }
        saveLibrariesCache()
        environment.trust.update(connections: connections, credentials: environment.credentials)
        if connections.isEmpty, isOffline {
            isOffline = false
        }
    }

    public func removeAll() async {
        for connection in connections {
            await remove(connection.id)
        }
    }

    private func replaceClient(for connection: Connection) async {
        if let old = clients.removeValue(forKey: connection.id) {
            await old.disconnectSocket()
        }
        hearth?.stopLiveUpdates(for: connection.id)
        clients[connection.id] = environment.clientFactory(connection, environment.tokenStore, relay)
        status[connection.id] = .loading
        environment.trust.update(connections: connections, credentials: environment.credentials)
    }

    // MARK: Libraries & reachability

    public func reloadLibraries() async {
        await reloadLibraries(only: nil)
    }

    func reloadLibraries(only ids: Set<ConnectionID>?) async {
        guard offlineReason != .user else { return }
        let targets = connections.filter { ids?.contains($0.id) ?? true }
        guard !targets.isEmpty else { return }

        // Probe even while automatically offline.
        APINetworkPolicy.shared.isOffline = false

        let clients = targets.compactMap { connection in (try? client(for: connection.id)).map { (connection.id, $0) } }
        for (id, _) in clients {
            status[id] = .loading
        }
        let results = await withTaskGroup(of: (ConnectionID, Result<[Library], any Error>).self) { group in
            for (id, client) in clients {
                group.addTask {
                    do {
                        return (id, .success(try await client.libraries()))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }
            var results = [(ConnectionID, Result<[Library], any Error>)]()
            for await result in group {
                results.append(result)
            }
            return results
        }

        for (id, result) in results {
            switch result {
            case .success(let fetched):
                libraries[id] = fetched.sorted { $0.displayOrder < $1.displayOrder }
                status[id] = .online
            case .failure(let error):
                logger.error("Loading libraries of \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                if (error as? APIError) == .unauthorized {
                    markUnauthorized(id)
                } else {
                    status[id] = .offline
                }
            }
        }
        saveLibrariesCache()
        evaluateReachability()
    }

    /// Enters offline mode when no connection is reachable, leaves automatic offline mode when one is.
    private func evaluateReachability() {
        guard offlineReason != .user, !connections.isEmpty else {
            APINetworkPolicy.shared.isOffline = isOffline
            return
        }
        let statuses = connections.map { status[$0.id] ?? .loading }
        if statuses.contains(.online) || statuses.contains(.loading) {
            if isOffline {
                isOffline = false
            }
        } else if statuses.contains(.offline) {
            if !isOffline {
                logger.info("No server reachable, entering offline mode")
                offlineReason = isNetworkAvailable ? .unreachable : .noNetwork
                isOffline = true
            }
        }
        APINetworkPolicy.shared.isOffline = isOffline
    }

    public func retryOffline() async {
        offlineReason = nil
        isOffline = false
        if let hearth {
            await hearth.refresh()
        } else {
            await reloadLibraries()
        }
    }

    public func setOffline(_ offline: Bool) async {
        if offline {
            offlineReason = .user
            isOffline = true
        } else {
            await retryOffline()
        }
    }

    public func isUsingLegacyAuthentication(_ id: ConnectionID) async -> Bool {
        environment.tokenStore.cachedOrStoredTokens(for: id)?.isLegacy ?? false
    }

    func markUnauthorized(_ id: ConnectionID) {
        guard connection(id) != nil else { return }
        status[id] = .unauthorized
        if connectionNeedingReauthorization == nil {
            connectionNeedingReauthorization = id
        }
    }

    private func saveLibrariesCache() {
        guard let data = JSON.encode(libraries) else { return }
        try? data.write(to: librariesCacheURL, options: .atomic)
    }

    // MARK: Client certificates (mTLS)

    /// Imports a PKCS#12 client certificate for a server. Validates the passphrase before storing it.
    public func importClientCertificate(_ data: Data, passphrase: String, for host: URL) throws(ClientCertificateError) {
        _ = try PKCS12.importIdentity(data, passphrase: passphrase)
        environment.credentials.saveClientCertificate(ClientCertificate(pkcs12: data, passphrase: passphrase), for: ClientIdentityKey.make(host))
        environment.trust.update(connections: connections, credentials: environment.credentials)
        // TODO: Once HearthAPI exposes `APIClientFactory.clientIdentityProvider`, set it to `clientIdentity(for:)`
        // in `HearthData.init` so API requests and the socket present the certificate too.
    }

    public func hasClientCertificate(for host: URL) -> Bool {
        environment.credentials.clientCertificate(for: ClientIdentityKey.make(host)) != nil
    }

    public func removeClientCertificate(for host: URL) {
        environment.credentials.deleteClientCertificate(for: ClientIdentityKey.make(host))
        environment.trust.update(connections: connections, credentials: environment.credentials)
    }

    /// The imported client identity for a server, if any (also usable before the connection exists).
    public nonisolated func clientIdentity(for host: URL) -> ClientIdentity? {
        if let identity = environment.trust.identity(for: host) {
            return identity
        }
        guard let certificate = environment.credentials.clientCertificate(for: ClientIdentityKey.make(host)) else { return nil }
        return try? PKCS12.importIdentity(certificate.pkcs12, passphrase: certificate.passphrase)
    }
}
