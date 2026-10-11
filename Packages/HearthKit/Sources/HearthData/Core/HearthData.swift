// Public surface of HearthData (formerly `DataContract.swift`). Names and signatures used by HearthPlayback,
// HearthIntents, HearthUI and the apps must stay source compatible.

import Foundation
import HearthAPI
import HearthModel
import Observation
import os

// MARK: - Composition root

/// Owns every data service. Created once per process (app, widget extension, watch app).
@MainActor
@Observable
public final class HearthData {
    public static let shared = HearthData(environment: .live(), settings: .shared)

    public let settings: AppSettings
    public let connections: ConnectionStore
    public let progress: ProgressStore
    public let bookmarks: BookmarkStore
    public let downloads: DownloadManager
    public let items: ItemRepository
    public let listening: ListeningTracker
    public let itemSettings: ItemSettingsStore
    public let images: ImageStore
    public let snapshot: SharedSnapshotStore

    /// `true` once `bootstrap()` finished.
    public internal(set) var isBootstrapped = false
    /// `true` while `refresh()` runs.
    public internal(set) var isRefreshing = false

    @ObservationIgnored let environment: DataEnvironment
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var liveUpdateTasks: [ConnectionID: Task<Void, Never>] = [:]
    @ObservationIgnored private var wantsLiveUpdates = false
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var autoDownloadTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(category: "HearthData")

    init(environment: DataEnvironment, settings: AppSettings) {
        self.environment = environment
        self.settings = settings
        connections = ConnectionStore(environment: environment)
        progress = ProgressStore(environment: environment)
        bookmarks = BookmarkStore(environment: environment)
        downloads = DownloadManager(environment: environment)
        items = ItemRepository(environment: environment)
        listening = ListeningTracker(environment: environment)
        itemSettings = ItemSettingsStore(environment: environment)
        images = ImageStore(environment: environment)
        snapshot = SharedSnapshotStore(environment: environment)

        connections.hearth = self
        progress.hearth = self
        bookmarks.hearth = self
        downloads.hearth = self
        items.hearth = self
        listening.hearth = self
        itemSettings.hearth = self
        snapshot.hearth = self
        images.configure(ImageStore.Dependencies(
            client: { [weak self] id in await self?.availableClient(id) },
            localCover: { [weak self] id, size in await self?.downloads.localCoverURL(for: id, size: size) }
        ))
        if environment.isLive {
            // mTLS for API requests, the socket and the add-connection flow (provisional ids).
            let trust = environment.trust
            APIClientFactory.clientIdentityProvider = { id in trust.identity(forConnectionID: id) }
        }
        APINetworkPolicy.shared.isOffline = connections.isOffline
    }

    private func availableClient(_ id: ConnectionID) -> (any AudiobookshelfClient)? {
        guard connections.isAvailable(id) else { return nil }
        return try? connections.client(for: id)
    }

    // MARK: Lifecycle

    /// Called once at launch by the app: loads connections, opens the database, starts sync, uploads pending sessions.
    ///
    /// Order: connections → libraries → upload local sessions → progress & bookmark sync → close stale sessions →
    /// listened today → Listen Now snapshot → resume downloads → automatic downloads.
    public func bootstrap() async {
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }
        let task = Task { await performBootstrap() }
        bootstrapTask = task
        await task.value
    }

    private func performBootstrap() async {
        if !connections.isLoaded {
            connections.load()
        }
        connections.startMonitoring()
        await connections.reloadLibraries()
        await listening.uploadPendingSessions()
        await progress.sync()
        await listening.closeStaleSessions()
        await listening.refresh()
        await updateListenNowSnapshot()
        await downloads.resumePendingDownloads()
        isBootstrapped = true
        await downloads.runAutoDownloads()
    }

    /// Re-sync everything (pull-to-refresh on root, app foregrounding).
    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        await connections.reloadLibraries()
        guard !connections.isOffline else {
            await listening.refresh()
            await updateListenNowSnapshot()
            return
        }
        await listening.uploadPendingSessions()
        await progress.sync()
        await listening.closeStaleSessions()
        await listening.refresh()
        await updateListenNowSnapshot()
        await downloads.resumePendingDownloads()
        if wantsLiveUpdates {
            startLiveUpdates()
        }
        await downloads.runAutoDownloads()
    }

    /// Deletes caches (not downloads).
    public func purgeCache() async {
        items.purge()
        await images.purge()
        let caches = environment.cachesURL
        await Task.detached(priority: .utility) { FileSystem.removeContents(of: caches) }.value
        URLCache.shared.removeAllCachedResponses()
    }

    /// Size of caches in bytes.
    public func cacheSize() async -> Int64 {
        let caches = environment.cachesURL
        return await Task.detached(priority: .utility) { FileSystem.size(of: caches) }.value
    }

    // MARK: Live updates (Socket.IO)

    /// Connects the sockets of all available connections and applies their events. Call while the app is in the
    /// foreground; sockets reconnect automatically after offline periods.
    public func startLiveUpdates() {
        wantsLiveUpdates = true
        guard !connections.isOffline else { return }
        for connection in connections.connections where connections.isAvailable(connection.id) && liveUpdateTasks[connection.id] == nil {
            guard let client = try? connections.client(for: connection.id) else { continue }
            let id = connection.id
            let stream = client.events()
            liveUpdateTasks[id] = Task { [weak self] in
                Task { await client.connectSocket() }
                for await event in stream {
                    guard !Task.isCancelled else { break }
                    await self?.handle(event, connection: id)
                }
            }
        }
    }

    /// Disconnects all sockets (app moved to the background).
    public func stopLiveUpdates() {
        wantsLiveUpdates = false
        disconnectSockets()
    }

    private func disconnectSockets() {
        for (id, task) in liveUpdateTasks {
            task.cancel()
            if let client = try? connections.client(for: id) {
                Task { await client.disconnectSocket() }
            }
        }
        liveUpdateTasks.removeAll()
    }

    func stopLiveUpdates(for id: ConnectionID) {
        liveUpdateTasks.removeValue(forKey: id)?.cancel()
    }

    func handle(_ event: ServerEvent, connection: ConnectionID) async {
        switch event {
        case .progressUpdated(let entity):
            await progress.applyLive(entity)
        case .itemUpdated(let id), .itemRemoved(let id):
            items.invalidate(id)
        case .userUpdated:
            await progress.sync(connection: connection)
        case .itemAdded, .connected, .disconnected:
            break
        }
    }

    // MARK: Internal notifications

    func offlineModeChanged() {
        if connections.isOffline {
            for task in liveUpdateTasks.values {
                task.cancel()
            }
            liveUpdateTasks.removeAll()
        } else if wantsLiveUpdates {
            startLiveUpdates()
        }
        scheduleSnapshotUpdate()
    }

    func connectionBecameAvailable(_ id: ConnectionID) async {
        guard connections.isAvailable(id) else { return }
        await progress.sync(connection: id)
        await listening.refresh()
        if wantsLiveUpdates {
            startLiveUpdates()
        }
        await updateListenNowSnapshot()
    }

    /// Removes everything stored for a connection (downloads, database rows, caches).
    func purgeConnection(_ id: ConnectionID) async {
        await downloads.removeAll(connection: id)
        await environment.store.perform { $0.deleteAll(connectionID: id) }
        progress.forget(connection: id)
        bookmarks.forget(connection: id)
        items.forget(connection: id)
        itemSettings.forget(connection: id)
        listening.forget(connection: id)
        await images.purge(connection: id)
        snapshot.update { snapshot in
            snapshot.listenNow.removeAll { $0.id.connectionID == id }
            if snapshot.nowPlaying?.id.connectionID == id {
                snapshot.nowPlaying = nil
                snapshot.isPlaying = false
            }
        }
    }

    func progressFinishedStateChanged(_ id: ItemIdentifier, finished: Bool) {
        scheduleSnapshotUpdate()
        if finished {
            Task { await downloads.runAutoDownloads() }
        }
    }

    func downloadsChanged() {
        scheduleSnapshotUpdate()
    }

    /// An item entered or left Listen Now (started, finished, reset, hidden, remote change).
    func listenNowChanged() {
        scheduleSnapshotUpdate()
        guard environment.isLive, settings.autoDownloadsEnabled, settings.autoDownloadListenNow else { return }
        autoDownloadTask?.cancel()
        autoDownloadTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await downloads.runAutoDownloads()
        }
    }

    func listenedTodayChanged() {
        let listened = listening.listenedToday
        let goal = settings.dailyGoalMinutes
        snapshot.update {
            $0.listenedToday = listened
            $0.dailyGoalMinutes = goal
        }
    }

    // MARK: Snapshot

    private func scheduleSnapshotUpdate() {
        guard environment.isLive else { return }
        snapshotTask?.cancel()
        snapshotTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await updateListenNowSnapshot()
        }
    }

    /// Rewrites the Listen Now part of the widget snapshot.
    public func updateListenNowSnapshot() async {
        let playables = await items.listenNow()
        var entries = [SharedSnapshot.Entry]()
        for item in playables.prefix(8) {
            let progress = progress.peek(item.id)
            let subtitle: String? = switch item {
            case .audiobook(let audiobook): audiobook.authorLine
            case .episode(let episode): episode.podcastName
            }
            entries.append(SharedSnapshot.Entry(
                id: item.id,
                title: item.name,
                subtitle: subtitle,
                progress: progress?.progress ?? 0,
                remaining: progress?.remaining ?? (item.duration > 0 ? item.duration : nil),
                isDownloaded: downloads.status(of: item.id) == .completed,
                coverFile: await snapshot.storeCover(for: item.id)
            ))
        }
        let listened = listening.listenedToday
        let goal = settings.dailyGoalMinutes
        let tint = settings.tintColor
        snapshot.update {
            $0.listenNow = entries
            $0.listenedToday = listened
            $0.dailyGoalMinutes = goal
            $0.tint = tint
        }
        snapshot.removeUnusedCovers()
    }
}
