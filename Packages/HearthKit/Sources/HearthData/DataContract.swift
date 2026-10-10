// CONTRACT FILE – public surface of HearthData.
// The bodies here are TEMPORARY STUBS. The HearthData implementer replaces them (and may split the
// types into multiple files), but must keep these public names and signatures source compatible.
// Adding members or default parameters is fine.

import Foundation
import HearthAPI
import HearthModel
import Observation

// MARK: - Composition root

/// Owns every data service. Created once per process (app, widget extension, watch app).
@MainActor
@Observable
public final class HearthData {
    public static let shared = HearthData()

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

    private init() {
        settings = .shared
        connections = ConnectionStore()
        progress = ProgressStore()
        bookmarks = BookmarkStore()
        downloads = DownloadManager()
        items = ItemRepository()
        listening = ListeningTracker()
        itemSettings = ItemSettingsStore()
        images = ImageStore()
        snapshot = SharedSnapshotStore()
    }

    /// Called once at launch by the app: loads connections, opens the database, starts sync, uploads pending sessions.
    public func bootstrap() async {}

    /// Re-sync everything (pull-to-refresh on root, app foregrounding).
    public func refresh() async {}

    /// Deletes caches (not downloads).
    public func purgeCache() async {}

    /// Size of caches in bytes.
    public func cacheSize() async -> Int64 { 0 }
}

// MARK: - Connections

public enum ConnectionStatus: Hashable, Sendable {
    case loading
    case online
    case offline
    case unauthorized
}

public struct KnownServer: Hashable, Codable, Sendable, Identifiable {
    public var host: URL
    public var username: String
    public var id: String { "\(host.absoluteString)|\(username)" }

    public init(host: URL, username: String) {
        self.host = host
        self.username = username
    }
}

@MainActor
@Observable
public final class ConnectionStore {
    public internal(set) var isLoaded = false
    public internal(set) var connections: [Connection] = []
    public internal(set) var libraries: [ConnectionID: [Library]] = [:]
    public internal(set) var status: [ConnectionID: ConnectionStatus] = [:]
    public internal(set) var knownServers: [KnownServer] = []

    /// Global offline mode (user toggle or automatic when no server is reachable).
    public var isOffline = false

    /// The connection that needs re-authentication (UI presents a sheet), if any.
    public var connectionNeedingReauthorization: ConnectionID?

    init() {}

    /// All libraries of all connections, ordered by connection then display order.
    public var allLibraries: [Library] { connections.flatMap { libraries[$0.id] ?? [] } }

    public func library(_ id: LibraryIdentifier) -> Library? {
        libraries[id.connectionID]?.first { $0.id == id }
    }

    public func connection(_ id: ConnectionID) -> Connection? {
        connections.first { $0.id == id }
    }

    public func client(for id: ConnectionID) throws -> any AudiobookshelfClient {
        throw APIError.unreachable
    }

    public func add(_ connection: Connection, tokens: AuthTokens) async {}
    public func update(_ connection: Connection) async {}
    public func updateTokens(_ tokens: AuthTokens, for id: ConnectionID) async {}
    public func remove(_ id: ConnectionID) async {}
    public func removeAll() async {}
    public func reloadLibraries() async {}
    public func retryOffline() async {}
    public func setOffline(_ offline: Bool) async {}
    public func isUsingLegacyAuthentication(_ id: ConnectionID) async -> Bool { false }
}

// MARK: - Progress

@MainActor
@Observable
public final class ProgressStore {
    init() {}

    /// Observable lookup (UI re-renders when this item's progress changes).
    public func progress(for id: ItemIdentifier) -> ProgressEntity? { nil }

    /// Called by the playback reporter.
    public func update(_ id: ItemIdentifier, currentTime: TimeInterval, duration: TimeInterval) async {}
    public func setFinished(_ id: ItemIdentifier, finished: Bool) async throws {}
    public func reset(_ id: ItemIdentifier) async throws {}
    public func hideFromContinueListening(_ id: ItemIdentifier) async throws {}

    /// Items in progress across all connections, most recent first.
    public func inProgress() -> [ProgressEntity] { [] }

    /// Full reconcile with the server(s).
    public func sync() async {}
    public func sync(connection: ConnectionID) async {}
}

// MARK: - Bookmarks

@MainActor
@Observable
public final class BookmarkStore {
    init() {}

    public func bookmarks(for id: ItemIdentifier) -> [Bookmark] { [] }
    /// Item ids (audiobooks) with at least one bookmark, with counts.
    public func bookmarkedItems(in library: LibraryIdentifier) -> [(itemID: ItemIdentifier, count: Int)] { [] }

    @discardableResult
    public func create(_ id: ItemIdentifier, time: TimeInterval, note: String?) async throws -> Bookmark {
        Bookmark(itemID: id, time: Int(time), note: note ?? "", created: .now)
    }

    public func update(_ bookmark: Bookmark, note: String) async throws {}
    public func delete(_ bookmark: Bookmark) async throws {}
    public func sync() async {}
}

// MARK: - Downloads

public struct LocalPlaybackInfo: Sendable, Hashable {
    public var tracks: [AudioTrack]
    public var chapters: [Chapter]

    public init(tracks: [AudioTrack], chapters: [Chapter]) {
        self.tracks = tracks
        self.chapters = chapters
    }
}

public enum DownloadError: Error, Sendable {
    case itemIsPlaying
    case itemIsDownloading
    case notDownloadable
    case cellularNotAllowed
}

@MainActor
@Observable
public final class DownloadManager {
    init() {}

    public func status(of id: ItemIdentifier) -> DownloadStatus { .none }
    /// 0...1 weighted progress while downloading.
    public func progress(of id: ItemIdentifier) -> Double { 0 }

    public func download(_ id: ItemIdentifier) async throws {}
    public func download(_ ids: [ItemIdentifier]) async {}
    public func remove(_ id: ItemIdentifier) async {}
    public func cancel(_ id: ItemIdentifier) async {}
    public func removeAll() async {}

    public func downloadedAudiobooks(in library: LibraryIdentifier? = nil) -> [Audiobook] { [] }
    public func downloadedPodcasts(in library: LibraryIdentifier? = nil) -> [Podcast] { [] }
    public func downloadedEpisodes(podcast: ItemIdentifier? = nil) -> [Episode] { [] }

    public func localPlayback(for id: ItemIdentifier) -> LocalPlaybackInfo? { nil }
    public func localCoverURL(for id: ItemIdentifier) -> URL? { nil }
    public func localPDFURL(for id: ItemIdentifier, ino: String) -> URL? { nil }

    /// Locks an item while it plays so it can't be removed.
    public func lock(_ id: ItemIdentifier) {}
    public func unlock(_ id: ItemIdentifier) {}

    public func storageUsed() async -> Int64 { 0 }

    /// Forwarded from `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    public func handleBackgroundEvents(identifier: String, completion: @escaping @Sendable () -> Void) { completion() }

    // MARK: Automatic downloads

    public func autoDownloadRule(for grouping: ItemIdentifier) -> AutoDownloadRule { .disabled }
    public func setAutoDownloadRule(_ rule: AutoDownloadRule, for grouping: ItemIdentifier) async {}
    /// Groupings that have a rule configured.
    public func autoDownloadConfigurations() -> [(grouping: ItemIdentifier, rule: AutoDownloadRule)] { [] }
    public func isAutomaticallyDownloaded(_ id: ItemIdentifier) -> Bool { false }
    /// Evaluates all rules; called from background refresh, after finishing items, after Listen Now changes.
    public func runAutoDownloads() async {}
    /// Called when an item finished playing (removes download if configured, schedules follow-ups).
    public func itemFinished(_ id: ItemIdentifier) async {}
}

// MARK: - Items

public enum SearchScope: Hashable, Sendable {
    case library(LibraryIdentifier)
    case everywhere
    case downloadsOnly
}

/// Resolves items with memory/disk caching and offline fallback to downloads.
@MainActor
@Observable
public final class ItemRepository {
    init() {}

    public func item(_ id: ItemIdentifier) async throws -> AnyItem { throw APIError.notFound }
    public func playable(_ id: ItemIdentifier) async throws -> AnyPlayableItem { throw APIError.notFound }
    public func playableDetails(_ id: ItemIdentifier) async throws -> PlayableItemDetails { throw APIError.notFound }
    public func podcast(_ id: ItemIdentifier) async throws -> (podcast: Podcast, episodes: [Episode]) { throw APIError.notFound }

    /// In-progress items across all connections (offline: downloaded only), most recent first.
    public func listenNow() async -> [AnyPlayableItem] { [] }

    public func search(_ query: String, scope: SearchScope) async -> SearchResults { SearchResults() }

    /// Next items for Up Next generation.
    public func upNext(after id: ItemIdentifier, origin: PlaybackOrigin) async -> [AnyPlayableItem] { [] }

    /// First item to play for a grouping (first unfinished book of a series, next episode of a podcast, …).
    public func firstPlayable(in grouping: ItemIdentifier) async throws -> AnyPlayableItem { throw APIError.notFound }

    public func invalidate(_ id: ItemIdentifier) {}
}

// MARK: - Listening time

@MainActor
@Observable
public final class ListeningTracker {
    init() {}

    /// Seconds listened today (server + local + current unreported).
    public internal(set) var listenedToday: TimeInterval = 0

    public func refresh() async {}

    /// Adds unreported time from the current session (called by the player).
    public func addUnreported(_ seconds: TimeInterval) {}

    // Local session bookkeeping (used by the playback reporter when the server can't be reached).
    public func recordLocalSession(itemID: ItemIdentifier, startTime: TimeInterval, currentTime: TimeInterval, duration: TimeInterval, timeListened: TimeInterval) async {}
    public func closeLocalSession(itemID: ItemIdentifier) async {}
    public func uploadPendingSessions() async {}

    // Open server sessions (closed on next launch if the app crashed).
    public func registerOpenSession(_ sessionID: String, itemID: ItemIdentifier) {}
    public func unregisterOpenSession(_ sessionID: String) {}
    public func closeStaleSessions() async {}

    public func listeningSessions(for id: ItemIdentifier) async throws -> [ListeningSession] { [] }
    public func stats(connection: ConnectionID) async throws -> ListeningStats { throw APIError.unreachable }

    /// Persistent random device id + model info sent with sessions.
    public var deviceInfo: DeviceInfo {
        DeviceInfo(deviceID: "stub", clientVersion: "0", model: "stub", osName: "iOS", osVersion: "0")
    }
}

// MARK: - Per-item settings

public struct EpisodeListSettings: Hashable, Codable, Sendable {
    public var sort: EpisodeSortOrder
    public var direction: SortDirection
    public var filter: ProgressFilter
    public var downloadedOnly: Bool
    public var season: String?

    public init(sort: EpisodeSortOrder, direction: SortDirection, filter: ProgressFilter = .notFinished, downloadedOnly: Bool = false, season: String? = nil) {
        self.sort = sort
        self.direction = direction
        self.filter = filter
        self.downloadedOnly = downloadedOnly
        self.season = season
    }
}

/// Per audiobook / series / podcast / collection settings.
@MainActor
@Observable
public final class ItemSettingsStore {
    init() {}

    public func playbackRate(for id: ItemIdentifier) -> Double? { nil }
    public func setPlaybackRate(_ rate: Double?, for id: ItemIdentifier) {}

    public func sleepTimer(for id: ItemIdentifier) -> SleepTimerPreset? { nil }
    public func setSleepTimer(_ preset: SleepTimerPreset?, for id: ItemIdentifier) {}

    public func upNextStrategy(for id: ItemIdentifier) -> UpNextStrategy { .default }
    public func setUpNextStrategy(_ strategy: UpNextStrategy, for id: ItemIdentifier) {}

    public func allowsSuggestions(for id: ItemIdentifier) -> Bool { true }
    public func setAllowsSuggestions(_ allowed: Bool, for id: ItemIdentifier) {}

    public func episodeListSettings(for podcast: ItemIdentifier) -> EpisodeListSettings {
        EpisodeListSettings(sort: .released, direction: .descending)
    }
    public func setEpisodeListSettings(_ settings: EpisodeListSettings, for podcast: ItemIdentifier) {}

    /// Applies filter & sort to episodes (uses progress + downloads).
    public func apply(_ settings: EpisodeListSettings, to episodes: [Episode]) -> [Episode] { episodes }

    /// Library list display state (synced via iCloud KVS).
    public func displayMode(for key: String) -> DisplayMode { .grid }
    public func setDisplayMode(_ mode: DisplayMode, for key: String) {}
    public func librarySort<Sort: RawRepresentable & Sendable>(for key: String, default: Sort) -> (Sort, SortDirection) where Sort.RawValue == String { (`default`, .ascending) }
    public func setLibrarySort<Sort: RawRepresentable & Sendable>(_ sort: Sort, direction: SortDirection, for key: String) where Sort.RawValue == String {}

    /// Tabs configured for a library (iPhone tab bar) and pinned tabs.
    public func tabs(for library: LibraryIdentifier) -> [LibraryTab]? { nil }
    public func setTabs(_ tabs: [LibraryTab], for library: LibraryIdentifier) {}
    public var pinnedTabs: [PinnedTab] = []
}

public enum DisplayMode: String, Codable, Sendable, CaseIterable {
    case grid
    case list
}

public enum LibraryTab: String, Codable, Sendable, CaseIterable, Hashable {
    case home
    case library
    case latest
    case series
    case authors
    case narrators
    case bookmarks
    case collections
    case playlists
    case downloaded
    case statistics

    public static func available(for mediaType: Library.MediaType) -> [LibraryTab] {
        switch mediaType {
        case .audiobooks: [.home, .library, .series, .authors, .narrators, .bookmarks, .collections, .playlists, .downloaded, .statistics]
        case .podcasts: [.home, .latest, .library, .playlists, .downloaded, .statistics]
        }
    }

    public static func defaults(for mediaType: Library.MediaType) -> [LibraryTab] {
        switch mediaType {
        case .audiobooks: [.home, .library, .series, .authors]
        case .podcasts: [.home, .latest, .library]
        }
    }
}

public struct PinnedTab: Hashable, Codable, Sendable, Identifiable {
    public var library: LibraryIdentifier
    public var tab: LibraryTab
    public var id: String { "\(library)::\(tab.rawValue)" }

    public init(library: LibraryIdentifier, tab: LibraryTab) {
        self.library = library
        self.tab = tab
    }
}

// MARK: - Images

/// Disk + memory cache for covers and author images (raw image data, platform independent).
public final class ImageStore: Sendable {
    init() {}

    /// Returns cached or fetched image data. Uses downloaded covers first.
    public func imageData(for id: ItemIdentifier, size: ImageSize) async -> Data? { nil }

    /// Dominant color of the cover as sRGB components (0...1), cached.
    public func dominantColor(for id: ItemIdentifier) async -> RGBColor? { nil }

    public func purge() async {}
}

public struct RGBColor: Hashable, Codable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Relative luminance (0...1).
    public var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
    public var isLight: Bool { luminance > 0.6 }
}

// MARK: - Widget / extension snapshot

/// Data the app shares with widgets, controls, Live Activities and the watch.
public struct SharedSnapshot: Codable, Sendable, Hashable {
    public struct Entry: Codable, Sendable, Hashable, Identifiable {
        public var id: ItemIdentifier
        public var title: String
        public var subtitle: String?
        public var progress: Double
        public var remaining: TimeInterval?
        public var isDownloaded: Bool
        /// Small cover (JPEG) file name inside `SharedSnapshotStore.imagesDirectory`.
        public var coverFile: String?

        public init(id: ItemIdentifier, title: String, subtitle: String?, progress: Double, remaining: TimeInterval?, isDownloaded: Bool, coverFile: String?) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.progress = progress
            self.remaining = remaining
            self.isDownloaded = isDownloaded
            self.coverFile = coverFile
        }
    }

    public var nowPlaying: Entry?
    public var isPlaying: Bool
    public var chapterTitle: String?
    public var sleepTimer: SleepTimerState?
    public var listenNow: [Entry]
    public var listenedToday: TimeInterval
    public var dailyGoalMinutes: Int
    public var tint: TintColor
    public var updatedAt: Date

    public init(nowPlaying: Entry? = nil, isPlaying: Bool = false, chapterTitle: String? = nil, sleepTimer: SleepTimerState? = nil, listenNow: [Entry] = [], listenedToday: TimeInterval = 0, dailyGoalMinutes: Int = 30, tint: TintColor = .hearth, updatedAt: Date = .now) {
        self.nowPlaying = nowPlaying
        self.isPlaying = isPlaying
        self.chapterTitle = chapterTitle
        self.sleepTimer = sleepTimer
        self.listenNow = listenNow
        self.listenedToday = listenedToday
        self.dailyGoalMinutes = dailyGoalMinutes
        self.tint = tint
        self.updatedAt = updatedAt
    }
}

@MainActor
public final class SharedSnapshotStore {
    init() {}

    public static var imagesDirectory: URL { AppGroup.directory("Snapshot") }

    /// Readable from any process (widgets).
    public nonisolated static func read() -> SharedSnapshot { SharedSnapshot() }

    /// Mutates and persists the snapshot, then reloads widgets/controls (debounced).
    public func update(_ mutate: (inout SharedSnapshot) -> Void) {}

    /// Writes a small cover for `id` into the snapshot images directory, returns the file name.
    public func storeCover(for id: ItemIdentifier) async -> String? { nil }
}
