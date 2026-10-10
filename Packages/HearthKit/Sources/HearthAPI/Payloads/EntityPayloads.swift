import Foundation

struct LibrariesResponsePayload: Decodable, Sendable {
    var libraries: [LibraryPayload]

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        libraries = c.array("libraries")
    }
}

struct LibraryPayload: Decodable, Sendable {
    var id: String
    var name: String
    var mediaType: String?
    var displayOrder: Int
    var icon: String?

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        guard let id = c.nonEmptyString("id") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Library without id"))
        }
        self.id = id
        name = c.string("name") ?? ""
        mediaType = c.nonEmptyString("mediaType")
        displayOrder = c.int("displayOrder") ?? 0
        icon = c.nonEmptyString("icon")
    }
}

/// `GET api/libraries/{id}?include=filterdata`.
struct LibraryWithFilterDataPayload: Decodable, Sendable {
    var filterdata: FilterDataPayload?

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        filterdata = c.decode("filterdata")
    }
}

struct FilterDataPayload: Decodable, Sendable {
    var genres: [String]
    var tags: [String]
    var languages: [String]

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        genres = c.strings("genres")
        tags = c.strings("tags")
        languages = c.strings("languages")
    }
}

/// `{results, total}` list responses.
struct PagedPayload<Element: Decodable & Sendable>: Decodable, Sendable {
    var results: [Element]
    var total: Int?

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        results = c.array("results")
        total = c.int("total")
    }
}

/// `api/libraries/{id}/authors` returns `{results, total}` (paged) or `{authors}` (older/unpaged).
struct AuthorsResponsePayload: Decodable, Sendable {
    var authors: [AuthorPayload]
    var total: Int?

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        if c.contains("results") {
            authors = c.array("results")
        } else {
            authors = c.array("authors")
        }
        total = c.int("total")
    }
}

struct AuthorPayload: Decodable, Sendable {
    var id: String
    var libraryID: String?
    var name: String
    var description: String?
    var imagePath: String?
    var addedAt: Date?
    var numBooks: Int?
    /// `?include=items`
    var libraryItems: [LibraryItemPayload]
    /// `?include=items,series`
    var series: [AuthorSeriesPayload]

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        guard let id = c.nonEmptyString("id") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Author without id"))
        }
        self.id = id
        libraryID = c.nonEmptyString("libraryId")
        name = c.string("name") ?? ""
        description = c.nonEmptyString("description")
        imagePath = c.nonEmptyString("imagePath")
        addedAt = c.dateMS("addedAt")
        numBooks = c.int("numBooks")
        libraryItems = c.array("libraryItems")
        series = c.array("series")
    }
}

/// Series grouping in the author detail response: `{id, name, items[]}`.
struct AuthorSeriesPayload: Decodable, Sendable {
    var id: String
    var name: String
    var items: [LibraryItemPayload]

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        guard let id = c.nonEmptyString("id") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Series without id"))
        }
        self.id = id
        name = c.string("name") ?? ""
        items = c.contains("items") ? c.array("items") : c.array("books")
    }
}

struct NarratorsResponsePayload: Decodable, Sendable {
    var narrators: [NarratorPayload]

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        narrators = c.array("narrators")
    }
}

struct NarratorPayload: Decodable, Sendable {
    var id: String?
    var name: String
    var numBooks: Int?

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        guard let name = c.nonEmptyString("name") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Narrator without name"))
        }
        id = c.nonEmptyString("id")
        self.name = name
        numBooks = c.int("numBooks")
    }
}

struct SeriesPayload: Decodable, Sendable {
    var id: String
    var name: String
    var description: String?
    var addedAt: Date?
    var libraryID: String?
    var totalDuration: Double?
    var books: [LibraryItemPayload]
    var hasBooks: Bool

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        guard let id = c.nonEmptyString("id") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Series without id"))
        }
        self.id = id
        name = c.string("name") ?? ""
        description = c.nonEmptyString("description")
        addedAt = c.dateMS("addedAt")
        libraryID = c.nonEmptyString("libraryId")
        totalDuration = c.double("totalDuration")
        hasBooks = c.contains("books")
        books = c.array("books")
    }
}

struct CollectionPayload: Decodable, Sendable {
    var id: String
    var libraryID: String?
    var name: String
    var description: String?
    var createdAt: Date?
    /// Collections: expanded books.
    var books: [LibraryItemPayload]
    /// Playlists: `{libraryItemId, episodeId?, libraryItem, episode?}`.
    var items: [PlaylistItemPayload]

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        guard let id = c.nonEmptyString("id") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Collection without id"))
        }
        self.id = id
        libraryID = c.nonEmptyString("libraryId")
        name = c.string("name") ?? ""
        description = c.nonEmptyString("description")
        createdAt = c.dateMS("createdAt")
        books = c.array("books")
        items = c.array("items")
    }
}

struct PlaylistItemPayload: Decodable, Sendable {
    var libraryItemID: String?
    var episodeID: String?
    var libraryItem: LibraryItemPayload?
    var episode: EpisodePayload?

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        libraryItemID = c.nonEmptyString("libraryItemId")
        episodeID = c.nonEmptyString("episodeId")
        libraryItem = c.decode("libraryItem")
        episode = c.decode("episode")
    }
}

/// `GET api/libraries/{id}/personalized` shelf. Entities are decoded according to `type`.
struct ShelfPayload: Decodable, Sendable {
    enum Entities: Sendable {
        case libraryItems([LibraryItemPayload])
        case series([SeriesPayload])
        case authors([AuthorPayload])
        case unsupported
    }

    var id: String
    var label: String
    var labelStringKey: String?
    var type: String
    var entities: Entities

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        type = c.string("type") ?? ""
        id = c.nonEmptyString("id") ?? type
        label = c.string("label") ?? ""
        labelStringKey = c.nonEmptyString("labelStringKey")
        switch type {
        case "book", "podcast", "episode":
            entities = .libraryItems(c.array("entities"))
        case "series":
            entities = .series(c.array("entities"))
        case "authors":
            entities = .authors(c.array("entities"))
        default:
            entities = .unsupported
        }
    }
}

struct SearchResponsePayload: Decodable, Sendable {
    var books: [LibraryItemPayload]
    var podcasts: [LibraryItemPayload]
    var episodes: [LibraryItemPayload]
    var authors: [AuthorPayload]
    var narrators: [NarratorPayload]
    var series: [SearchSeriesPayload]

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        books = c.array("book", of: SearchItemPayload.self).map(\.libraryItem)
        podcasts = c.array("podcast", of: SearchItemPayload.self).map(\.libraryItem)
        episodes = c.array("episodes", of: SearchItemPayload.self).map(\.libraryItem)
        authors = c.array("authors")
        narrators = c.array("narrators")
        series = c.array("series")
    }
}

struct SearchItemPayload: Decodable, Sendable {
    var libraryItem: LibraryItemPayload
}

struct SearchSeriesPayload: Decodable, Sendable {
    var series: SeriesPayload
    var books: [LibraryItemPayload]

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        guard let series = c.decode("series", as: SeriesPayload.self) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Search series without series"))
        }
        self.series = series
        books = c.array("books")
    }
}

struct RecentEpisodesPayload: Decodable, Sendable {
    var episodes: [EpisodePayload]

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        episodes = c.array("episodes")
    }
}

/// `POST api/items/batch/get`.
struct BatchItemsPayload: Decodable, Sendable {
    var libraryItems: [LibraryItemPayload]

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        libraryItems = c.array("libraryItems")
    }
}

/// Any response carrying an `id` (created collections/playlists).
struct IdentifiedPayload: Decodable, Sendable {
    var id: String
}
