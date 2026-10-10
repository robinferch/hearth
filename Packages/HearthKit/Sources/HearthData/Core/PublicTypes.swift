import Foundation
import HearthAPI
import HearthModel

// MARK: - Connections

public enum ConnectionStatus: Hashable, Sendable {
    case loading
    case online
    case offline
    case unauthorized
}

/// Why the app is in offline mode.
public enum OfflineReason: Hashable, Sendable {
    /// The user enabled offline mode.
    case user
    /// No network path is available.
    case noNetwork
    /// The network is up but no server could be reached.
    case unreachable
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

// MARK: - Items

public enum SearchScope: Hashable, Sendable {
    case library(LibraryIdentifier)
    case everywhere
    case downloadsOnly
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
