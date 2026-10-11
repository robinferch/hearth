import AppIntents
import BackgroundTasks
import CoreSpotlight
import HearthData
import HearthIntents
import HearthModel
import OSLog
import Synchronization

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
    private static let indexedDomainsKey = "spotlight.indexedLibraries"
    private static let pageSize = 100
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hearth", category: "Spotlight")

    private let index = CSSearchableIndex(name: (Bundle.main.bundleIdentifier ?? "dev.hearth.hearth") + ".items")
    private var runningTask: Task<Int, Never>?

    private init() {}

    var lastFullIndex: Date? {
        UserDefaults.standard.object(forKey: Self.lastIndexKey) as? Date
    }

    /// Domain identifiers (`LibraryIdentifier.description`) of the libraries in the index.
    private var indexedDomains: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.indexedDomainsKey) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: Self.indexedDomainsKey) }
    }

    private var isDue: Bool {
        guard let lastFullIndex else { return true }
        return Date.now.timeIntervalSince(lastFullIndex) > Self.reindexInterval
    }

    // MARK: Scheduling

    func registerBackgroundTask() {
        // The launch handler runs on a background queue, so it must not be isolated to the main actor: a closure
        // written in this class would be, and Swift 6 traps on its isolation check when the system calls it.
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil, launchHandler: Self.handleLaunch)
        if !registered {
            Self.logger.error("Registering the Spotlight background task failed")
        }
    }

    /// Called by `BGTaskScheduler` on a background queue.
    nonisolated static func handleLaunch(_ task: BGTask) {
        let completion = BackgroundTaskCompletion(task)
        let work = Task { @MainActor in
            let success = await SpotlightIndexer.shared.runBackgroundTask()
            completion.finish(success: success)
        }
        // Also called on a background queue.
        task.expirationHandler = { @Sendable in
            // Out of time: stop indexing (completed libraries are kept) and report the task as incomplete.
            work.cancel()
            completion.finish(success: false)
        }
    }

    private func runBackgroundTask() async -> Bool {
        Self.logger.notice("Spotlight background task started")
        await HearthData.shared.bootstrap()
        let count = await indexAll()
        schedule()
        return count >= 0 && !Task.isCancelled
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

    /// Re-indexes everything. Returns the number of indexed items, or -1 when a library failed or the run was
    /// cancelled. Cancelling the caller cancels the run.
    @discardableResult
    func indexAll() async -> Int {
        let task: Task<Int, Never>
        if let runningTask {
            task = runningTask
        } else {
            task = Task { await performIndexAll() }
            runningTask = task
        }
        let count = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if runningTask == task {
            runningTask = nil
        }
        return count
    }

    /// Indexes library by library. A library's entries are only replaced once all of its pages (and covers) were
    /// loaded, so a failed or cancelled run keeps the previous entries. Libraries that are gone are removed;
    /// items deleted on the server disappear with the next successful run (or expire after twice the interval).
    private func performIndexAll() async -> Int {
        let data = HearthData.shared
        let started = Date.now
        var count = 0
        var failures = 0
        var domains = indexedDomains
        for library in data.connections.allLibraries {
            guard !Task.isCancelled else { break }
            do {
                count += try await index(library)
                domains.insert(library.id.description)
            } catch is CancellationError {
                break
            } catch {
                failures += 1
                Self.logger.error("Indexing \(library.name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
        guard !Task.isCancelled else {
            indexedDomains = domains
            Self.logger.notice("Spotlight indexing was cancelled after \(count) items")
            return -1
        }

        do {
            // Libraries (or whole connections) that are gone. With no library loaded, only a sign-out counts.
            let current = Set(data.connections.allLibraries.map(\.id.description))
            if !current.isEmpty || data.connections.connections.isEmpty {
                let removed = domains.subtracting(current)
                if !removed.isEmpty {
                    try await index.deleteSearchableItems(withDomainIdentifiers: Array(removed))
                    domains.subtract(removed)
                }
            }
            indexedDomains = domains

            let downloaded = await downloadedItems()
            try await index.indexSearchableItems(downloaded)
            count += downloaded.count
        } catch {
            Self.logger.error("Spotlight indexing failed: \(error.localizedDescription, privacy: .public)")
            return -1
        }

        guard failures == 0 else {
            // Not marked as done: the next launch / background task tries again.
            Self.logger.notice("Indexed \(count) items in Spotlight; \(failures) libraries failed")
            return -1
        }
        UserDefaults.standard.set(Date.now, forKey: Self.lastIndexKey)
        Self.logger.notice("Indexed \(count) items in Spotlight in \(Date.now.timeIntervalSince(started), format: .fixed(precision: 1)) s")
        return count
    }

    /// Loads all items of a library (pages of 100), then replaces its entries in the index. Returns the item count.
    private func index(_ library: Library) async throws -> Int {
        let client = try HearthData.shared.connections.client(for: library.connectionID)
        let started = Date.now
        var items = [CSSearchableItem]()
        var page = 0
        while true {
            try Task.checkCancellation()
            let received: Int
            let total: Int
            switch library.mediaType {
            case .audiobooks:
                let result = try await client.audiobooks(library: library.id, sort: .title, direction: .ascending, filter: nil, collapseSeries: false, page: page, limit: Self.pageSize)
                let books = result.items.compactMap { entry -> Audiobook? in
                    if case .audiobook(let audiobook) = entry { audiobook } else { nil }
                }
                items += await searchableItems(audiobooks: books)
                (received, total) = (result.items.count, result.total)
            case .podcasts:
                let result = try await client.podcasts(library: library.id, sort: .title, direction: .ascending, page: page, limit: Self.pageSize)
                items += await searchableItems(podcasts: result.items)
                (received, total) = (result.items.count, result.total)
            }
            page += 1
            if received < Self.pageSize || page * Self.pageSize >= total {
                break
            }
        }
        try Task.checkCancellation()

        let indexStart = Date.now
        try await index.deleteSearchableItems(withDomainIdentifiers: [library.id.description])
        for chunk in stride(from: 0, to: items.count, by: Self.pageSize) {
            try await index.indexSearchableItems(Array(items[chunk..<min(items.count, chunk + Self.pageSize)]))
        }
        Self.logger.debug("Indexed \(library.name, privacy: .public) (\(items.count) items) in \(Date.now.timeIntervalSince(started), format: .fixed(precision: 2)) s, writing took \(Date.now.timeIntervalSince(indexStart), format: .fixed(precision: 2)) s")
        return items.count
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
            UserDefaults.standard.removeObject(forKey: Self.indexedDomainsKey)
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

/// Calls `setTaskCompleted(success:)` exactly once (the work and the expiration handler race).
private final class BackgroundTaskCompletion: Sendable {
    // `BGTask` isn't `Sendable`; completing it is allowed from any thread.
    private nonisolated(unsafe) let task: BGTask
    private let isFinished = Mutex(false)

    init(_ task: BGTask) {
        self.task = task
    }

    func finish(success: Bool) {
        let isFirst = isFinished.withLock { finished in
            defer { finished = true }
            return !finished
        }
        guard isFirst else { return }
        task.setTaskCompleted(success: success)
    }
}
