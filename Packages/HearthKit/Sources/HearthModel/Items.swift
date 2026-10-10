import Foundation

/// Common surface of every browsable entity.
public protocol Item: Identifiable, Hashable, Codable, Sendable where ID == ItemIdentifier {
    var id: ItemIdentifier { get }
    var name: String { get }
    var authors: [String] { get }
    /// HTML or plain text description as delivered by the server.
    var descriptionHTML: String? { get }
    var genres: [String] { get }
    var addedAt: Date? { get }
    var released: String? { get }
}

public extension Item {
    var authorLine: String? {
        authors.isEmpty ? nil : authors.formatted(.list(type: .and, width: .short))
    }

    /// Lowercased name without leading articles, used for client side sorting.
    var sortName: String {
        let lowered = name.lowercased()
        for prefix in ["the ", "a ", "an ", "der ", "die ", "das ", "ein ", "eine "] where lowered.hasPrefix(prefix) {
            return String(lowered.dropFirst(prefix.count))
        }
        return lowered
    }
}

/// Audiobooks and podcast episodes.
public protocol PlayableItem: Item {
    var duration: TimeInterval { get }
    var size: Int64? { get }
    /// Name of the container (podcast name for episodes, first series for books).
    var subtitleLine: String? { get }
}

public struct Audiobook: PlayableItem {
    public let id: ItemIdentifier
    public var name: String
    public var subtitle: String?
    public var authors: [String]
    public var narrators: [String]
    public var series: [SeriesFragment]
    public var descriptionHTML: String?
    public var genres: [String]
    public var tags: [String]
    public var addedAt: Date?
    public var released: String?
    public var publisher: String?
    public var language: String?
    public var isbn: String?
    public var asin: String?
    public var explicit: Bool
    public var abridged: Bool
    public var duration: TimeInterval
    public var size: Int64?
    public var pdfs: [PDFFile]
    public var hasAudio: Bool

    public init(id: ItemIdentifier, name: String, subtitle: String? = nil, authors: [String] = [], narrators: [String] = [], series: [SeriesFragment] = [], descriptionHTML: String? = nil, genres: [String] = [], tags: [String] = [], addedAt: Date? = nil, released: String? = nil, publisher: String? = nil, language: String? = nil, isbn: String? = nil, asin: String? = nil, explicit: Bool = false, abridged: Bool = false, duration: TimeInterval = 0, size: Int64? = nil, pdfs: [PDFFile] = [], hasAudio: Bool = true) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.authors = authors
        self.narrators = narrators
        self.series = series
        self.descriptionHTML = descriptionHTML
        self.genres = genres
        self.tags = tags
        self.addedAt = addedAt
        self.released = released
        self.publisher = publisher
        self.language = language
        self.isbn = isbn
        self.asin = asin
        self.explicit = explicit
        self.abridged = abridged
        self.duration = duration
        self.size = size
        self.pdfs = pdfs
        self.hasAudio = hasAudio
    }

    public var subtitleLine: String? { series.first?.formatted ?? subtitle }
}

public struct SeriesFragment: Hashable, Codable, Sendable {
    public var id: String?
    public var name: String
    public var sequence: String?

    public init(id: String?, name: String, sequence: String?) {
        self.id = id
        self.name = name
        self.sequence = sequence
    }

    public var formatted: String {
        if let sequence, !sequence.isEmpty {
            "\(name) #\(sequence)"
        } else {
            name
        }
    }
}

public struct Podcast: Item {
    public enum PublishingType: String, Codable, Sendable {
        case episodic
        case serial
    }

    public let id: ItemIdentifier
    public var name: String
    public var authors: [String]
    public var descriptionHTML: String?
    public var genres: [String]
    public var addedAt: Date?
    public var released: String?
    public var explicit: Bool
    public var publishingType: PublishingType
    public var episodeCount: Int
    public var incompleteEpisodeCount: Int?
    public var feedURL: URL?
    public var language: String?

    public init(id: ItemIdentifier, name: String, authors: [String] = [], descriptionHTML: String? = nil, genres: [String] = [], addedAt: Date? = nil, released: String? = nil, explicit: Bool = false, publishingType: PublishingType = .episodic, episodeCount: Int = 0, incompleteEpisodeCount: Int? = nil, feedURL: URL? = nil, language: String? = nil) {
        self.id = id
        self.name = name
        self.authors = authors
        self.descriptionHTML = descriptionHTML
        self.genres = genres
        self.addedAt = addedAt
        self.released = released
        self.explicit = explicit
        self.publishingType = publishingType
        self.episodeCount = episodeCount
        self.incompleteEpisodeCount = incompleteEpisodeCount
        self.feedURL = feedURL
        self.language = language
    }
}

public struct Episode: PlayableItem {
    public enum EpisodeType: String, Codable, Sendable, CaseIterable {
        case full
        case trailer
        case bonus
    }

    public let id: ItemIdentifier
    public var name: String
    public var podcastName: String
    public var authors: [String]
    public var descriptionHTML: String?
    public var genres: [String] { [] }
    public var addedAt: Date?
    public var publishedAt: Date?
    public var season: String?
    public var episode: String?
    public var type: EpisodeType
    public var duration: TimeInterval
    public var size: Int64?

    public init(id: ItemIdentifier, name: String, podcastName: String, authors: [String] = [], descriptionHTML: String? = nil, addedAt: Date? = nil, publishedAt: Date? = nil, season: String? = nil, episode: String? = nil, type: EpisodeType = .full, duration: TimeInterval = 0, size: Int64? = nil) {
        self.id = id
        self.name = name
        self.podcastName = podcastName
        self.authors = authors
        self.descriptionHTML = descriptionHTML
        self.addedAt = addedAt
        self.publishedAt = publishedAt
        self.season = season
        self.episode = episode
        self.type = type
        self.duration = duration
        self.size = size
    }

    public var released: String? { publishedAt?.formatted(date: .abbreviated, time: .omitted) }
    public var subtitleLine: String? { podcastName }

    enum CodingKeys: String, CodingKey {
        case id, name, podcastName, authors, descriptionHTML, addedAt, publishedAt, season, episode, type, duration, size
    }
}

/// Authors and narrators.
public struct Person: Item {
    public let id: ItemIdentifier
    public var name: String
    public var descriptionHTML: String?
    public var addedAt: Date?
    public var bookCount: Int
    public var hasImage: Bool

    public var authors: [String] { [] }
    public var genres: [String] { [] }
    public var released: String? { nil }

    public init(id: ItemIdentifier, name: String, descriptionHTML: String? = nil, addedAt: Date? = nil, bookCount: Int = 0, hasImage: Bool = false) {
        self.id = id
        self.name = name
        self.descriptionHTML = descriptionHTML
        self.addedAt = addedAt
        self.bookCount = bookCount
        self.hasImage = hasImage
    }

    enum CodingKeys: String, CodingKey {
        case id, name, descriptionHTML, addedAt, bookCount, hasImage
    }
}

public struct Series: Item {
    public let id: ItemIdentifier
    public var name: String
    public var descriptionHTML: String?
    public var addedAt: Date?
    public var audiobooks: [Audiobook]
    public var bookCount: Int
    public var totalDuration: TimeInterval?

    public var authors: [String] {
        var seen = Set<String>()
        return audiobooks.flatMap(\.authors).filter { seen.insert($0).inserted }
    }

    public var genres: [String] { [] }
    public var released: String? { nil }

    public init(id: ItemIdentifier, name: String, descriptionHTML: String? = nil, addedAt: Date? = nil, audiobooks: [Audiobook] = [], bookCount: Int? = nil, totalDuration: TimeInterval? = nil) {
        self.id = id
        self.name = name
        self.descriptionHTML = descriptionHTML
        self.addedAt = addedAt
        self.audiobooks = audiobooks
        self.bookCount = bookCount ?? audiobooks.count
        self.totalDuration = totalDuration
    }

    enum CodingKeys: String, CodingKey {
        case id, name, descriptionHTML, addedAt, audiobooks, bookCount, totalDuration
    }
}

/// Collections (audiobooks only) and playlists (audiobooks and episodes).
public struct ItemCollection: Item {
    public let id: ItemIdentifier
    public var name: String
    public var descriptionHTML: String?
    public var addedAt: Date?
    public var items: [AnyPlayableItem]

    public var authors: [String] { [] }
    public var genres: [String] { [] }
    public var released: String? { nil }

    public var isPlaylist: Bool { id.kind == .playlist }

    public init(id: ItemIdentifier, name: String, descriptionHTML: String? = nil, addedAt: Date? = nil, items: [AnyPlayableItem] = []) {
        self.id = id
        self.name = name
        self.descriptionHTML = descriptionHTML
        self.addedAt = addedAt
        self.items = items
    }

    enum CodingKeys: String, CodingKey {
        case id, name, descriptionHTML, addedAt, items
    }
}

/// Type-erased playable item for heterogeneous lists.
public enum AnyPlayableItem: Hashable, Codable, Sendable, Identifiable {
    case audiobook(Audiobook)
    case episode(Episode)

    public var id: ItemIdentifier { base.id }

    public var base: any PlayableItem {
        switch self {
        case .audiobook(let audiobook): audiobook
        case .episode(let episode): episode
        }
    }

    public var name: String { base.name }
    public var duration: TimeInterval { base.duration }
}

/// Type-erased item for heterogeneous lists (search results, home rows).
public enum AnyItem: Hashable, Codable, Sendable, Identifiable {
    case audiobook(Audiobook)
    case podcast(Podcast)
    case episode(Episode)
    case person(Person)
    case series(Series)
    case collection(ItemCollection)

    public var id: ItemIdentifier { base.id }

    public var base: any Item {
        switch self {
        case .audiobook(let item): item
        case .podcast(let item): item
        case .episode(let item): item
        case .person(let item): item
        case .series(let item): item
        case .collection(let item): item
        }
    }

    public var name: String { base.name }

    public var playable: AnyPlayableItem? {
        switch self {
        case .audiobook(let audiobook): .audiobook(audiobook)
        case .episode(let episode): .episode(episode)
        default: nil
        }
    }

    public init(_ playable: AnyPlayableItem) {
        switch playable {
        case .audiobook(let audiobook): self = .audiobook(audiobook)
        case .episode(let episode): self = .episode(episode)
        }
    }
}

/// Entry in a library list: either a book or a series that was collapsed by the server.
public enum LibraryEntry: Hashable, Sendable, Identifiable {
    case audiobook(Audiobook)
    case collapsedSeries(Series)

    public var id: ItemIdentifier {
        switch self {
        case .audiobook(let audiobook): audiobook.id
        case .collapsedSeries(let series): series.id
        }
    }
}

public struct Chapter: Hashable, Codable, Sendable, Identifiable {
    public let id: Int
    public var start: TimeInterval
    public var end: TimeInterval
    public var title: String

    public init(id: Int, start: TimeInterval, end: TimeInterval, title: String) {
        self.id = id
        self.start = start
        self.end = end
        self.title = title
    }

    public var duration: TimeInterval { max(0, end - start) }

    public func contains(_ time: TimeInterval) -> Bool {
        time >= start && time < end
    }
}

public struct Bookmark: Hashable, Codable, Sendable, Identifiable {
    public let itemID: ItemIdentifier
    /// Whole seconds. Together with the item this is the bookmark's identity.
    public let time: Int
    public var note: String
    public var created: Date

    public init(itemID: ItemIdentifier, time: Int, note: String, created: Date) {
        self.itemID = itemID
        self.time = time
        self.note = note
        self.created = created
    }

    public var id: String { "\(itemID)_\(time)" }
}

public struct PDFFile: Hashable, Codable, Sendable, Identifiable {
    public let ino: String
    public var name: String

    public init(ino: String, name: String) {
        self.ino = ino
        self.name = name
    }

    public var id: String { ino }
}

/// Audio file of a playable item, used for downloads.
public struct AudioFile: Hashable, Codable, Sendable {
    public var ino: String
    public var fileExtension: String
    public var offset: TimeInterval
    public var duration: TimeInterval
    public var mimeType: String?

    public init(ino: String, fileExtension: String, offset: TimeInterval, duration: TimeInterval, mimeType: String? = nil) {
        self.ino = ino
        self.fileExtension = fileExtension
        self.offset = offset
        self.duration = duration
        self.mimeType = mimeType
    }
}

/// A playable audio track, either streamed or local.
public struct AudioTrack: Hashable, Codable, Sendable {
    public var index: Int
    public var offset: TimeInterval
    public var duration: TimeInterval
    public var url: URL
    public var mimeType: String?

    public init(index: Int, offset: TimeInterval, duration: TimeInterval, url: URL, mimeType: String? = nil) {
        self.index = index
        self.offset = offset
        self.duration = duration
        self.url = url
        self.mimeType = mimeType
    }

    public var end: TimeInterval { offset + duration }
}

public struct HomeRow: Hashable, Sendable, Identifiable {
    public let id: String
    public var label: String
    public var items: [AnyItem]

    public init(id: String, label: String, items: [AnyItem]) {
        self.id = id
        self.label = label
        self.items = items
    }
}
