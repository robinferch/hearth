import AppIntents
import BackgroundTasks
import CoreSpotlight
import HearthData
import HearthIntents
import HearthModel
import OSLog

/// Indexes audiobooks and podcasts of all libraries (plus downloaded items) in Core Spotlight.
///
/// - Full index: all libraries, pages of 100, via a `BGProcessingTask` (`<bundle>.spotlight`, needs network) or
///   at launch when the index is older than 21 days.
/// - Downloaded audiobooks and episodes are re-indexed on every launch (cheap, works offline).
/// - Items are associated with their App Intents entities, so Spotlight can offer actions on them.
/// - Tapping a result continues `CSSearchableItemActionType` with the item identifier (see `systemIntegrationHandlers()`).
@MainActor
final class SpotlightIndexer {
    static let shared = SpotlightIndexer()

    static let taskIdentifier = (Bundle.main.bundleIdentifier ?? "dev.hearth.hearth") + ".spotlight"
    static let reindexInterval: TimeInterval = 21 * 24 * 3600
    private static let lastIndexKey = "spotlight.lastFullIndex"
    private static let pageSize = 100
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hearth", category: "Spotlight")

    private let index = CSSearchableIndex(name: (Bundle.main.bundleIdentifier ?? "dev.hearth.hearth") + ".items")
    private var runningTask: Task<Int, Never>?

    private init() {}

    var lastFullIndex: Date? {
        UserDefaults.standard.object(forKey: Self.lastIndexKey) as? Date
    }

    private var isDue: Bool {
        guard let lastFullIndex else { return true }
        return Date.now.timeIntervalSince(lastFullIndex) > Self.reindexInterval
    }

    // MARK: Scheduling

    func registerBackgroundTask() {
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { task in
            nonisolated(unsafe) let task = task
            Task { @MainActor in
                SpotlightIndexer.shared.handle(task)
            }
        }
        if !registered {
            Self.logger.error("Registering the Spotlight background task failed")
        }
    }

    private func handle(_ task: BGTask) {
        let work = Task {
            await HearthData.shared.bootstrap()
            let count = await indexAll()
            task.setTaskCompleted(success: count >= 0)
            schedule()
        }
        task.expirationHandler = {
            work.cancel()
        }
    }

    /// Schedules the next full index (when it becomes due).
    func schedule() {
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = lastFullIndex.map { $0.addingTimeInterval(Self.reindexInterval) } ?? .now
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Self.logger.notice("Scheduling the Spotlight task failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// After bootstrap: index downloads, run a full index when due (or never ran), schedule the next one.
    func launchUpdate() async {
        guard !HearthData.shared.connections.connections.isEmpty else { return }
        await indexDownloads()
        if isDue, !HearthData.shared.connections.isOffline {
            await indexAll()
        }
        schedule()
    }

    // MARK: Indexing

    /// Re-indexes everything. Returns the number of indexed items (or -1 on failure).
    @discardableResult
    func indexAll() async -> Int {
        if let runningTask {
            return await runningTask.value
        }
        let task = Task { await performIndexAll() }
        runningTask = task
        defer { runningTask = nil }
        return await task.value
    }

    /// Indexes page by page (keeps memory bounded for large libraries). Items of removed libraries/connections are
    /// dropped by clearing the index first; anything missed later expires after twice the re-index interval.
    private func performIndexAll() async -> Int {
        let data = HearthData.shared
        let started = Date.now
        var count = 0
        do {
            try await index.deleteAllSearchableItems()
            for library in data.connections.allLibraries {
                guard !Task.isCancelled, let client = try? data.connections.client(for: library.connectionID) else { continue }
                do {
                    var page = 0
                    while !Task.isCancelled {
                        let items: [CSSearchableItem]
                        let received: Int
                        let total: Int
                        switch library.mediaType {
                        case .audiobooks:
                            let result = try await client.audiobooks(library: library.id, sort: .title, direction: .ascending, filter: nil, collapseSeries: false, page: page, limit: Self.pageSize)
                            let books = result.items.compactMap { entry -> Audiobook? in
                                if case .audiobook(let audiobook) = entry { audiobook } else { nil }
                            }
                            items = await searchableItems(audiobooks: books)
                            (received, total) = (result.items.count, result.total)
                        case .podcasts:
                            let result = try await client.podcasts(library: library.id, sort: .title, direction: .ascending, page: page, limit: Self.pageSize)
                            items = await searchableItems(podcasts: result.items)
                            (received, total) = (result.items.count, result.total)
                        }
                        try await index.indexSearchableItems(items)
                        count += items.count
                        page += 1
                        if received < Self.pageSize || page * Self.pageSize >= total {
                            break
                        }
                    }
                } catch {
                    Self.logger.error("Indexing \(library.name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            }
            guard !Task.isCancelled else { return -1 }
            let downloaded = await downloadedItems()
            try await index.indexSearchableItems(downloaded)
            count += downloaded.count
            UserDefaults.standard.set(Date.now, forKey: Self.lastIndexKey)
            Self.logger.notice("Indexed \(count) items in Spotlight in \(Date.now.timeIntervalSince(started), format: .fixed(precision: 1)) s")
            return count
        } catch {
            Self.logger.error("Spotlight indexing failed: \(error.localizedDescription, privacy: .public)")
            return -1
        }
    }

    /// Downloaded audiobooks and episodes (available offline).
    func indexDownloads() async {
        let items = await downloadedItems()
        guard !items.isEmpty else { return }
        do {
            try await index.indexSearchableItems(items)
            Self.logger.notice("Indexed \(items.count) downloaded items in Spotlight")
        } catch {
            Self.logger.error("Indexing downloads failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes everything Hearth put into Spotlight.
    func purge() async {
        do {
            try await index.deleteAllSearchableItems()
            UserDefaults.standard.removeObject(forKey: Self.lastIndexKey)
        } catch {
            Self.logger.error("Purging the Spotlight index failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func downloadedItems() async -> [CSSearchableItem] {
        let downloads = HearthData.shared.downloads
        var items = await searchableItems(audiobooks: downloads.downloadedAudiobooks())
        let episodes = downloads.downloadedEpisodes()
        let images = await thumbnails(episodes.map(\.id))
        for episode in episodes {
            let entity = EpisodeEntity(episode, imageData: images[episode.id])
            items.append(searchableItem(id: episode.id, attributes: entity.attributeSet) { $0.associateAppEntity(entity, priority: 1) })
        }
        return items
    }

    private func searchableItems(audiobooks: [Audiobook]) async -> [CSSearchableItem] {
        let images = await thumbnails(audiobooks.map(\.id))
        return audiobooks.map { audiobook in
            let entity = AudiobookEntity(audiobook, imageData: images[audiobook.id])
            return searchableItem(id: audiobook.id, attributes: entity.attributeSet) { $0.associateAppEntity(entity, priority: 2) }
        }
    }

    private func searchableItems(podcasts: [Podcast]) async -> [CSSearchableItem] {
        let images = await thumbnails(podcasts.map(\.id))
        return podcasts.map { podcast in
            let entity = PodcastEntity(podcast, imageData: images[podcast.id])
            return searchableItem(id: podcast.id, attributes: entity.attributeSet) { $0.associateAppEntity(entity, priority: 2) }
        }
    }

    private func searchableItem(id: ItemIdentifier, attributes: CSSearchableItemAttributeSet, associate: (CSSearchableItem) -> Void) -> CSSearchableItem {
        let item = CSSearchableItem(uniqueIdentifier: id.description, domainIdentifier: id.library.description, attributeSet: attributes)
        item.expirationDate = Date.now.addingTimeInterval(Self.reindexInterval * 2)
        associate(item)
        return item
    }

    /// Small covers, at most 6 requests at a time.
    private func thumbnails(_ ids: [ItemIdentifier]) async -> [ItemIdentifier: Data] {
        let images = HearthData.shared.images
        var result = [ItemIdentifier: Data]()
        for chunk in stride(from: 0, to: ids.count, by: 6) {
            let slice = ids[chunk..<min(ids.count, chunk + 6)]
            await withTaskGroup(of: (ItemIdentifier, Data?).self) { group in
                for id in slice {
                    group.addTask { (id, await images.imageData(for: id, size: .tiny)) }
                }
                for await (id, data) in group {
                    result[id] = data
                }
            }
        }
        return result
    }
}
