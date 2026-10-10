import Foundation

public struct Library: Hashable, Codable, Sendable, Identifiable {
    public enum MediaType: String, Codable, Sendable {
        case audiobooks
        case podcasts
    }

    public let id: LibraryIdentifier
    public var name: String
    public var mediaType: MediaType
    public var displayOrder: Int
    public var icon: String?

    public init(id: LibraryIdentifier, name: String, mediaType: MediaType, displayOrder: Int, icon: String? = nil) {
        self.id = id
        self.name = name
        self.mediaType = mediaType
        self.displayOrder = displayOrder
        self.icon = icon
    }

    public var connectionID: ConnectionID { id.connectionID }

    /// SF Symbol for the library. Maps the audiobookshelf icon names where possible.
    public var systemImage: String {
        switch icon {
        case "podcast": "antenna.radiowaves.left.and.right"
        case "microphone", "microphone-1", "microphone-2", "microphone-3": "mic"
        case "radio": "radio"
        case "music": "music.note"
        case "headphones": "headphones"
        case "book", "books-1", "books-2": "books.vertical"
        case "book-1": "book"
        case "audiobookshelf": "books.vertical.fill"
        case "database": "cylinder"
        case "file-picture": "photo"
        case "heart": "heart"
        case "star": "star"
        case "rocket": "airplane"
        case "comic": "text.bubble"
        default: mediaType == .podcasts ? "antenna.radiowaves.left.and.right" : "books.vertical"
        }
    }
}

// MARK: - Sorting & filtering

public enum SortDirection: String, Codable, Sendable, CaseIterable {
    case ascending
    case descending

    public var isDescending: Bool { self == .descending }

    public mutating func toggle() {
        self = self == .ascending ? .descending : .ascending
    }
}

public enum AudiobookSortOrder: String, Codable, Sendable, CaseIterable {
    case title = "media.metadata.title"
    case author = "media.metadata.authorName"
    case authorLastFirst = "media.metadata.authorNameLF"
    case published = "media.metadata.publishedYear"
    case added = "addedAt"
    case duration = "media.duration"
    case size = "size"
    case lastUpdated = "progress"
}

public enum SeriesSortOrder: String, Codable, Sendable, CaseIterable {
    case name = "name"
    case bookCount = "numBooks"
    case added = "addedAt"
    case totalDuration = "totalDuration"
}

public enum AuthorSortOrder: String, Codable, Sendable, CaseIterable {
    case firstLast = "name"
    case lastFirst = "lastFirst"
    case bookCount = "numBooks"
    case added = "addedAt"
}

public enum NarratorSortOrder: String, Codable, Sendable, CaseIterable {
    case name
    case bookCount
}

public enum PodcastSortOrder: String, Codable, Sendable, CaseIterable {
    case title = "media.metadata.title"
    case author = "media.metadata.author"
    case episodeCount = "media.numTracks"
    case added = "addedAt"
}

public enum EpisodeSortOrder: String, Codable, Sendable, CaseIterable {
    case name
    case index
    case released
    case duration
}

public enum ProgressFilter: String, Codable, Sendable, CaseIterable {
    case all
    case notStarted = "not-started"
    case inProgress = "in-progress"
    case finished
    case notFinished = "not-finished"
}

/// Server side filter for `api/libraries/{id}/items`.
public enum LibraryItemFilter: Hashable, Codable, Sendable {
    case progress(ProgressFilter)
    case genre(String)
    case tag(String)
    case author(id: String)
    case narrator(name: String)
    case series(id: String)
    case language(String)

    /// The `filter` query value, `group.base64(value)`.
    public var queryValue: String? {
        func encoded(_ group: String, _ value: String) -> String {
            "\(group).\(Data(value.utf8).base64EncodedString())"
        }

        return switch self {
        case .progress(.all): nil
        case .progress(let filter): encoded("progress", filter.rawValue)
        case .genre(let genre): encoded("genres", genre)
        case .tag(let tag): encoded("tags", tag)
        case .author(let id): encoded("authors", id)
        case .narrator(let name): encoded("narrators", name)
        case .series(let id): encoded("series", id)
        case .language(let language): encoded("languages", language)
        }
    }
}

public struct Page<Element: Sendable>: Sendable {
    public var items: [Element]
    public var total: Int
    public var page: Int

    public init(items: [Element], total: Int, page: Int) {
        self.items = items
        self.total = total
        self.page = page
    }
}

extension Page: Equatable where Element: Equatable {}

public struct LibraryFilterData: Hashable, Codable, Sendable {
    public var genres: [String]
    public var tags: [String]
    public var languages: [String]

    public init(genres: [String] = [], tags: [String] = [], languages: [String] = []) {
        self.genres = genres
        self.tags = tags
        self.languages = languages
    }
}

public struct SearchResults: Sendable, Hashable {
    public var audiobooks: [Audiobook]
    public var podcasts: [Podcast]
    public var episodes: [Episode]
    public var authors: [Person]
    public var narrators: [Person]
    public var series: [Series]

    public init(audiobooks: [Audiobook] = [], podcasts: [Podcast] = [], episodes: [Episode] = [], authors: [Person] = [], narrators: [Person] = [], series: [Series] = []) {
        self.audiobooks = audiobooks
        self.podcasts = podcasts
        self.episodes = episodes
        self.authors = authors
        self.narrators = narrators
        self.series = series
    }

    public var isEmpty: Bool {
        audiobooks.isEmpty && podcasts.isEmpty && episodes.isEmpty && authors.isEmpty && narrators.isEmpty && series.isEmpty
    }

    public mutating func merge(_ other: SearchResults) {
        audiobooks += other.audiobooks
        podcasts += other.podcasts
        episodes += other.episodes
        authors += other.authors
        narrators += other.narrators
        series += other.series
    }
}
