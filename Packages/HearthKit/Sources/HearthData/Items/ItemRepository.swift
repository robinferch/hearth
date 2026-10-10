import Foundation
import HearthAPI
import HearthModel
import Observation
import os

/// Resolves items with memory/disk caching and offline fallback to downloads.
@MainActor
@Observable
public final class ItemRepository {
    /// Memory entries younger than this are returned without hitting the network.
    static let freshness: TimeInterval = 300

    private struct Cached {
        var item: AnyItem
        var fetchedAt: Date
    }

    private struct CachedPodcast {
        var podcast: Podcast
        var episodes: [Episode]
        var fetchedAt: Date
    }

    @ObservationIgnored private var memory = LRUCache<ItemIdentifier, Cached>(capacity: 600)
    @ObservationIgnored private var podcasts = LRUCache<ItemIdentifier, CachedPodcast>(capacity: 60)
    @ObservationIgnored private var inflight: [ItemIdentifier: Task<AnyItem, any Error>] = [:]
    @ObservationIgnored let environment: DataEnvironment
    @ObservationIgnored weak var hearth: HearthData?
    @ObservationIgnored private let disk: ItemDiskCache
    @ObservationIgnored private let logger = Logger(category: "ItemRepository")

    init(environment: DataEnvironment) {
        self.environment = environment
        disk = ItemDiskCache(root: environment.cachesURL.appending(path: "Items", directoryHint: .isDirectory))
    }

    // MARK: Helpers

    private func availableClient(for id: ItemIdentifier) -> (any AudiobookshelfClient)? {
        guard let connections = hearth?.connections, connections.isAvailable(id.connectionID) else { return nil }
        return try? connections.client(for: id.connectionID)
    }

    private func store(_ item: AnyItem) {
        memory.set(Cached(item: item, fetchedAt: .now), for: item.id)
        disk.write(item)
    }

    /// Memory-only lookup (no I/O).
    func cachedItem(_ id: ItemIdentifier) -> AnyItem? {
        memory.peek(id)?.item
    }

    func cachedPlayable(_ id: ItemIdentifier) -> AnyPlayableItem? {
        if let playable = memory.peek(id)?.item.playable {
            return playable
        }
        if let podcast = id.podcastIdentifier, let episode = podcasts.peek(podcast)?.episodes.first(where: { $0.id == id }) {
            return .episode(episode)
        }
        return nil
    }

    /// Seeds the memory cache with items fetched elsewhere (home rows, lists).
    public func remember(_ items: [AnyItem]) {
        for item in items {
            memory.set(Cached(item: item, fetchedAt: .now), for: item.id)
        }
    }

    nonisolated static func fetch(_ id: ItemIdentifier, client: any AudiobookshelfClient) async throws -> AnyItem {
        switch id.kind {
        case .audiobook: .audiobook(try await client.audiobook(id))
        case .podcast: .podcast(try await client.podcast(id).podcast)
        case .episode: .episode(try await client.episode(id))
        case .author: .person(try await client.author(id).author)
        case .narrator: .person(try await client.narrator(id).narrator)
        case .series: .series(try await client.seriesDetails(id))
        case .collection, .playlist: .collection(try await client.collection(id))
        }
    }

    private func offlineItem(_ id: ItemIdentifier) async -> AnyItem? {
        if let cached = memory.peek(id) {
            return cached.item
        }
        if let item = await disk.readItem(id) {
            memory.set(Cached(item: item, fetchedAt: .distantPast), for: id)
            return item
        }
        if let stored = await environment.store.perform({ $0.storedItem(id) }) {
            return stored.item
        }
        return nil
    }

    // MARK: Items

    public func item(_ id: ItemIdentifier) async throws -> AnyItem {
        if let cached = memory.value(for: id), Date.now.timeIntervalSince(cached.fetchedAt) < Self.freshness {
            return cached.item
        }
        if let client = availableClient(for: id) {
            do {
                let item: AnyItem
                if let task = inflight[id] {
                    item = try await task.value
                } else {
                    let task = Task { try await Self.fetch(id, client: client) }
                    inflight[id] = task
                    defer { inflight[id] = nil }
                    item = try await task.value
                }
                store(item)
                return item
            } catch {
                logger.debug("Fetching \(id.description, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                if let item = await offlineItem(id) {
                    return item
                }
                throw error
            }
        }
        if let item = await offlineItem(id) {
            return item
        }
        throw hearth?.connections.isOffline == true ? APIError.offline : APIError.notFound
    }

    public func playable(_ id: ItemIdentifier) async throws -> AnyPlayableItem {
        guard let playable = try await item(id).playable else {
            throw APIError.notFound
        }
        return playable
    }

    public func playableDetails(_ id: ItemIdentifier) async throws -> PlayableItemDetails {
        if let client = availableClient(for: id) {
            do {
                let details = try await client.playableDetails(id)
                store(AnyItem(details.item))
                return details
            } catch {
                if let local = await hearth?.downloads.offlineDetails(for: id) {
                    return local
                }
                throw error
            }
        }
        if let local = await hearth?.downloads.offlineDetails(for: id) {
            return local
        }
        throw hearth?.connections.isOffline == true ? APIError.offline : APIError.notFound
    }

    public func podcast(_ id: ItemIdentifier) async throws -> (podcast: Podcast, episodes: [Episode]) {
        if let cached = podcasts.value(for: id), Date.now.timeIntervalSince(cached.fetchedAt) < Self.freshness {
            return (cached.podcast, cached.episodes)
        }
        if let client = availableClient(for: id) {
            do {
                let (podcast, episodes) = try await client.podcast(id)
                podcasts.set(CachedPodcast(podcast: podcast, episodes: episodes, fetchedAt: .now), for: id)
                store(.podcast(podcast))
                disk.write(ItemDiskCache.PodcastEntry(podcast: podcast, episodes: episodes))
                return (podcast, episodes)
            } catch {
                if let offline = await offlinePodcast(id) {
                    return offline
                }
                throw error
            }
        }
        if let offline = await offlinePodcast(id) {
            return offline
        }
        throw hearth?.connections.isOffline == true ? APIError.offline : APIError.notFound
    }

    private func offlinePodcast(_ id: ItemIdentifier) async -> (podcast: Podcast, episodes: [Episode])? {
        if let cached = podcasts.peek(id) {
            return (cached.podcast, cached.episodes)
        }
        if let entry = await disk.readPodcast(id) {
            podcasts.set(CachedPodcast(podcast: entry.podcast, episodes: entry.episodes, fetchedAt: .distantPast), for: id)
            return (entry.podcast, entry.episodes)
        }
        let primaryID = id.primaryID
        let stored = await environment.store.perform { context in
            (context.storedItem(id), context.storedItems(downloadedOnly: true, kind: .episode, groupingID: primaryID))
        }
        guard case .podcast(let podcast)? = stored.0?.item else { return nil }
        let episodes = stored.1.compactMap { value -> Episode? in
            guard case .episode(let episode) = value.item, episode.id.connectionID == id.connectionID else { return nil }
            return episode
        }
        return (podcast, episodes)
    }

    // MARK: Listen Now

    /// In-progress items across all connections (offline: downloaded only), most recent first.
    public func listenNow() async -> [AnyPlayableItem] {
        guard let hearth else { return [] }
        let ids = ListenNowPlanner.order(
            hearth.progress.inProgress(),
            connections: Set(hearth.connections.connections.map(\.id)),
            offline: hearth.connections.isOffline,
            isDownloaded: { hearth.downloads.status(of: $0) == .completed }
        )
        return await concurrentCompactMap(ids) { id in
            try? await self.playable(id)
        }
    }

    // MARK: Search

    public func search(_ query: String, scope: SearchScope) async -> SearchResults {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let hearth else { return SearchResults() }

        var results = await searchDownloads(query, library: { if case .library(let library) = scope { library } else { nil } }())
        if scope == .downloadsOnly || hearth.connections.isOffline {
            return SearchRanker.rank(results, query: query)
        }

        let libraries: [Library]
        switch scope {
        case .library(let id):
            libraries = hearth.connections.library(id).map { [$0] } ?? []
        case .everywhere:
            libraries = hearth.connections.allLibraries
        case .downloadsOnly:
            libraries = []
        }
        let targets: [(LibraryIdentifier, any AudiobookshelfClient)] = libraries.compactMap { library in
            guard hearth.connections.isAvailable(library.connectionID), let client = try? hearth.connections.client(for: library.connectionID) else { return nil }
            return (library.id, client)
        }
        let remote = await concurrentCompactMap(targets) { target in
            try? await target.1.search(library: target.0, query: query, limit: 25)
        }
        for result in remote {
            results.merge(result)
        }
        return SearchRanker.rank(results, query: query)
    }

    private func searchDownloads(_ query: String, library: LibraryIdentifier?) async -> SearchResults {
        let tokens = SearchRanker.tokens(query)
        guard !tokens.isEmpty else { return SearchResults() }
        let matches = await environment.store.perform { $0.searchDownloadedItems(tokens: tokens) }
        var results = SearchResults()
        var podcastIDs = Set<ItemIdentifier>()
        for match in matches {
            if let library, match.item.id.library != library { continue }
            switch match.item {
            case .audiobook(let audiobook): results.audiobooks.append(audiobook)
            case .episode(let episode): results.episodes.append(episode)
            case .podcast(let podcast):
                if podcastIDs.insert(podcast.id).inserted {
                    results.podcasts.append(podcast)
                }
            default: break
            }
        }
        return results
    }

    // MARK: Up Next

    /// Next items for Up Next generation.
    public func upNext(after id: ItemIdentifier, origin: PlaybackOrigin) async -> [AnyPlayableItem] {
        guard let hearth else { return [] }
        let current: AnyPlayableItem
        if let cached = cachedPlayable(id) {
            current = cached
        } else if let fetched = try? await playable(id) {
            current = fetched
        } else {
            return []
        }
        let source = UpNextPlanner.source(origin: origin, item: current) { hearth.itemSettings.upNextStrategy(for: $0) }
        let isFinished: (ItemIdentifier) -> Bool = { hearth.progress.peek($0)?.isFinished ?? false }

        switch source {
        case .none:
            return []
        case .listenNow:
            return await listenNow().filter { $0.id.storageKey != id.storageKey }
        case .series(let series):
            let books = await seriesBooks(series).map(AnyPlayableItem.audiobook)
            return UpNextPlanner.following(id, in: books, isFinished: isFinished)
        case .podcast(let podcastID):
            guard let result = try? await podcast(podcastID) else { return [] }
            let ordered = hearth.itemSettings.apply(hearth.itemSettings.episodeListSettings(for: result.podcast), to: result.episodes).map(AnyPlayableItem.episode)
            return UpNextPlanner.excluding(id, from: ordered, isFinished: isFinished)
        case .collection(let collectionID):
            guard case .collection(let collection)? = try? await item(collectionID) else { return [] }
            return UpNextPlanner.following(id, in: collection.items, isFinished: isFinished)
        }
    }

    /// Books of a series in series order (server order without sort + series filter), with offline fallbacks.
    func seriesBooks(_ series: ItemIdentifier) async -> [Audiobook] {
        if let client = availableClient(for: series) {
            var books = [Audiobook]()
            var page = 0
            do {
                while page < 20 {
                    let result = try await client.audiobooks(library: series.library, sort: nil, direction: .ascending, filter: .series(id: series.primaryID), collapseSeries: false, page: page, limit: 100)
                    for entry in result.items {
                        if case .audiobook(let audiobook) = entry {
                            books.append(audiobook)
                        }
                    }
                    page += 1
                    if result.items.isEmpty || books.count >= result.total {
                        break
                    }
                }
                remember(books.map(AnyItem.audiobook))
                return books
            } catch {
                logger.debug("Loading series books failed: \(String(describing: error), privacy: .public)")
            }
        }
        if case .series(let details)? = await offlineItem(series), !details.audiobooks.isEmpty {
            return details.audiobooks
        }
        // Downloaded books of that series, by sequence.
        let downloaded = hearth?.downloads.downloadedAudiobooks(in: nil) ?? []
        return downloaded
            .filter { $0.id.connectionID == series.connectionID && $0.series.contains { $0.id == series.primaryID } }
            .sorted { lhs, rhs in
                let left = lhs.series.first { $0.id == series.primaryID }?.sequence
                let right = rhs.series.first { $0.id == series.primaryID }?.sequence
                return EpisodeListing.naturalCompare(left, right) == .orderedAscending
            }
    }

    /// First item to play for a grouping (first unfinished book of a series, next episode of a podcast, …).
    public func firstPlayable(in grouping: ItemIdentifier) async throws -> AnyPlayableItem {
        guard let hearth else { throw APIError.notFound }
        let isFinished: (ItemIdentifier) -> Bool = { hearth.progress.peek($0)?.isFinished ?? false }
        let candidate: AnyPlayableItem?
        switch grouping.kind {
        case .audiobook, .episode:
            return try await playable(grouping)
        case .series:
            candidate = UpNextPlanner.firstUnfinished(in: await seriesBooks(grouping).map(AnyPlayableItem.audiobook), isFinished: isFinished)
        case .podcast:
            let (podcast, episodes) = try await podcast(grouping)
            let ordered = hearth.itemSettings.apply(hearth.itemSettings.episodeListSettings(for: podcast), to: episodes)
            candidate = (ordered.first ?? EpisodeListing.sort(episodes, by: .released, direction: .descending).first).map(AnyPlayableItem.episode)
        case .collection, .playlist:
            guard case .collection(let collection) = try await item(grouping) else { throw APIError.notFound }
            candidate = UpNextPlanner.firstUnfinished(in: collection.items, isFinished: isFinished)
        case .author:
            guard let client = availableClient(for: grouping) else { throw APIError.offline }
            let books = try await client.author(grouping).audiobooks.sorted { ($0.released ?? "") < ($1.released ?? "") }
            candidate = UpNextPlanner.firstUnfinished(in: books.map(AnyPlayableItem.audiobook), isFinished: isFinished)
        case .narrator:
            guard let client = availableClient(for: grouping) else { throw APIError.offline }
            let books = try await client.narrator(grouping).audiobooks
            candidate = UpNextPlanner.firstUnfinished(in: books.map(AnyPlayableItem.audiobook), isFinished: isFinished)
        }
        guard let candidate else { throw APIError.notFound }
        return candidate
    }

    // MARK: Invalidation

    public func invalidate(_ id: ItemIdentifier) {
        memory.remove(id)
        podcasts.remove(id)
        if let podcast = id.podcastIdentifier {
            podcasts.remove(podcast)
        }
        disk.remove(id)
    }

    func purge() {
        memory.removeAll()
        podcasts.removeAll()
        disk.removeAll()
    }

    func forget(connection: ConnectionID) {
        memory.removeAll { $0.connectionID == connection }
        podcasts.removeAll { $0.connectionID == connection }
        disk.remove(connection: connection)
    }
}
