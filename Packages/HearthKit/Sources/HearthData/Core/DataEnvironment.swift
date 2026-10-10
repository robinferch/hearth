import Foundation
import HearthAPI
import HearthModel
import SwiftData

typealias ClientFactory = @Sendable (Connection, any TokenStore, (any APIClientDelegate)?) -> any AudiobookshelfClient

/// Dependencies shared by all HearthData services. `live()` is used by the apps; tests build their own with an
/// in-memory store, temporary directories and mock clients.
final class DataEnvironment: @unchecked Sendable {
    let container: ModelContainer
    let store: DataActor
    let credentials: any CredentialStoring
    let tokenStore: CredentialTokenStore
    let clientFactory: ClientFactory
    let defaults: UserDefaults
    let keyValueStore: any KeyValueSyncStore
    let trust: SessionTrust

    /// Root of downloaded files (`<connection>/<library>/<primary>/…`).
    let downloadsURL: URL
    /// Purgeable caches (items, images).
    let cachesURL: URL
    /// Non-purgeable support files (library cache, …).
    let supportURL: URL
    /// Shared snapshot for widgets.
    let snapshotURL: URL

    /// `false` in tests: no network monitor, background sessions, sockets or widget reloads.
    let isLive: Bool

    init(container: ModelContainer, credentials: any CredentialStoring, clientFactory: @escaping ClientFactory, defaults: UserDefaults, keyValueStore: any KeyValueSyncStore, downloadsURL: URL, cachesURL: URL, supportURL: URL, snapshotURL: URL, isLive: Bool) {
        self.container = container
        self.store = DataActor(modelContainer: container)
        self.credentials = credentials
        self.tokenStore = CredentialTokenStore(credentials: credentials)
        self.clientFactory = clientFactory
        self.defaults = defaults
        self.keyValueStore = keyValueStore
        self.trust = SessionTrust(credentials: credentials)
        self.downloadsURL = downloadsURL
        self.cachesURL = cachesURL
        self.supportURL = supportURL
        self.snapshotURL = snapshotURL
        self.isLive = isLive

        for url in [downloadsURL, cachesURL, supportURL, snapshotURL] {
            FileSystem.ensureDirectory(url)
        }
        FileSystem.excludeFromBackup(downloadsURL)
        FileSystem.excludeFromBackup(cachesURL)
    }

    static func live() -> DataEnvironment {
        DataEnvironment(
            container: Persistence.makeContainer(),
            credentials: KeychainCredentialStore(),
            clientFactory: { connection, tokenStore, delegate in
                APIClientFactory.makeClient(connection: connection, tokenStore: tokenStore, delegate: delegate)
            },
            defaults: AppGroup.defaults,
            keyValueStore: UbiquitousKeyValueStore(fallback: AppGroup.defaults),
            downloadsURL: AppGroup.downloadsURL,
            cachesURL: AppGroup.cachesURL,
            supportURL: AppGroup.directory("Library/Application Support"),
            snapshotURL: AppGroup.directory("Snapshot"),
            isLive: true
        )
    }

    /// Isolated environment for tests and previews.
    static func ephemeral(connections: [Connection] = [], tokens: [ConnectionID: AuthTokens] = [:], clientFactory: @escaping ClientFactory) -> DataEnvironment {
        let root = FileManager.default.temporaryDirectory.appending(path: "HearthTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let suite = "dev.hearth.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        return DataEnvironment(
            container: Persistence.makeContainer(inMemory: true),
            credentials: InMemoryCredentialStore(connections: connections, tokens: tokens),
            clientFactory: clientFactory,
            defaults: defaults,
            keyValueStore: InMemoryKeyValueStore(),
            downloadsURL: root.appending(path: "Downloads"),
            cachesURL: root.appending(path: "Caches"),
            supportURL: root.appending(path: "Support"),
            snapshotURL: root.appending(path: "Snapshot"),
            isLive: false
        )
    }
}
