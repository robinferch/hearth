import Foundation

/// A library item (book or podcast) in minified, normal or expanded form.
struct LibraryItemPayload: Decodable, Sendable {
    var id: String
    var libraryID: String?
    var mediaType: String?
    var addedAt: Date?
    var updatedAt: Date?
    var size: Int64?
    var media: MediaPayload?
    var libraryFiles: [LibraryFilePayload]
    /// Present in `collapseseries=1` item lists when the entry represents a whole series.
    var collapsedSeries: CollapsedSeriesPayload?
    /// Podcast shelves/search: the episode this entry is about.
    var recentEpisode: EpisodePayload?
    /// Podcast lists with `include=numEpisodesIncomplete`.
    var numEpisodesIncomplete: Int?
    /// Expanded item with `include=progress`.
    var userMediaProgress: MediaProgressPayload?

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        guard let id = c.nonEmptyString("id") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Library item without id"))
        }
        self.id = id
        libraryID = c.nonEmptyString("libraryId")
        mediaType = c.nonEmptyString("mediaType")
        addedAt = c.dateMS("addedAt")
        updatedAt = c.dateMS("updatedAt")
        size = c.int64("size")
        media = c.decode("media")
        libraryFiles = c.array("libraryFiles")
        collapsedSeries = c.decode("collapsedSeries")
        recentEpisode = c.decode("recentEpisode")
        numEpisodesIncomplete = c.int("numEpisodesIncomplete")
        userMediaProgress = c.decode("userMediaProgress")
    }

    var isPodcast: Bool {
        if let mediaType {
            return mediaType == "podcast"
        }
        // Older payloads without `mediaType`: podcasts carry episodes / podcast metadata.
        return media?.numEpisodes != nil || !(media?.episodes.isEmpty ?? true) || media?.metadata?.feedURL != nil
    }

    var isBook: Bool {
        mediaType == nil ? !isPodcast : mediaType == "book"
    }
}

/// `media` of a library item. Union of the book and podcast shapes.
struct MediaPayload: Decodable, Sendable {
    var id: String?
    var metadata: MediaMetadataPayload?
    var tags: [String]
    var duration: Double?
    var size: Int64?
    var numTracks: Int?
    var numAudioFiles: Int?
    var audioFiles: [AudioFilePayload]
    var tracks: [AudioTrackPayload]
    var chapters: [ChapterPayload]
    var ebookFormat: String?
    // Podcast
    var episodes: [EpisodePayload]
    var numEpisodes: Int?

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        id = c.nonEmptyString("id")
        metadata = c.decode("metadata")
        tags = c.strings("tags")
        duration = c.double("duration")
        size = c.int64("size")
        numTracks = c.int("numTracks")
        numAudioFiles = c.int("numAudioFiles")
        audioFiles = c.array("audioFiles")
        tracks = c.array("tracks")
        chapters = c.array("chapters")
        ebookFormat = c.nonEmptyString("ebookFormat")
        episodes = c.array("episodes")
        numEpisodes = c.int("numEpisodes")
    }

    /// Audio files that are not excluded, in playback order.
    var includedAudioFiles: [AudioFilePayload] {
        audioFiles.filter { !$0.exclude }.sorted { ($0.index ?? .max) < ($1.index ?? .max) }
    }

    var hasAudio: Bool {
        if !tracks.isEmpty || !includedAudioFiles.isEmpty {
            return true
        }
        if let numTracks {
            return numTracks > 0
        }
        if let numAudioFiles {
            return numAudioFiles > 0
        }
        return (duration ?? 0) > 0
    }
}

/// `media.metadata` for books and podcasts.
struct MediaMetadataPayload: Decodable, Sendable {
    var title: String?
    var subtitle: String?
    var description: String?
    var genres: [String]
    var language: String?
    var explicit: Bool
    // Books
    var authors: [NamedReferencePayload]
    var authorName: String?
    var narrators: [String]
    var narratorName: String?
    var series: [SeriesReferencePayload]
    var seriesName: String?
    var publishedYear: String?
    var publishedDate: String?
    var publisher: String?
    var isbn: String?
    var asin: String?
    var abridged: Bool
    // Podcasts
    var author: String?
    var releaseDate: String?
    var feedURL: String?
    var type: String?

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        title = c.string("title")
        subtitle = c.nonEmptyString("subtitle")
        description = c.nonEmptyString("description")
        genres = c.strings("genres")
        language = c.nonEmptyString("language")
        explicit = c.bool("explicit") ?? false
        authors = c.array("authors")
        authorName = c.nonEmptyString("authorName")
        narrators = c.strings("narrators")
        narratorName = c.nonEmptyString("narratorName")
        series = c.array("series")
        seriesName = c.nonEmptyString("seriesName")
        publishedYear = c.nonEmptyString("publishedYear")
        publishedDate = c.nonEmptyString("publishedDate")
        publisher = c.nonEmptyString("publisher")
        isbn = c.nonEmptyString("isbn")
        asin = c.nonEmptyString("asin")
        abridged = c.bool("abridged") ?? false
        author = c.nonEmptyString("author")
        releaseDate = c.nonEmptyString("releaseDate")
        feedURL = c.nonEmptyString("feedUrl")
        type = c.nonEmptyString("type")
    }
}

/// `{id, name}` – authors inside book metadata.
struct NamedReferencePayload: Decodable, Sendable {
    var id: String?
    var name: String

    init(from decoder: any Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            self.id = nil
            self.name = name
            return
        }
        let c = try decoder.lenient()
        guard let name = c.nonEmptyString("name") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Reference without name"))
        }
        self.id = c.nonEmptyString("id")
        self.name = name
    }
}

/// `{id, name, sequence}` – series inside book metadata.
struct SeriesReferencePayload: Decodable, Sendable {
    var id: String?
    var name: String
    var sequence: String?

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        guard let name = c.nonEmptyString("name") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Series without name"))
        }
        id = c.nonEmptyString("id")
        self.name = name
        sequence = c.nonEmptyString("sequence")
    }
}

struct CollapsedSeriesPayload: Decodable, Sendable {
    var id: String
    var name: String
    var numBooks: Int?
    var libraryItemIDs: [String]

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        guard let id = c.nonEmptyString("id") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Collapsed series without id"))
        }
        self.id = id
        name = c.string("name") ?? ""
        numBooks = c.int("numBooks")
        libraryItemIDs = c.strings("libraryItemIds")
    }
}

struct FileMetadataPayload: Decodable, Sendable {
    var filename: String?
    var ext: String?
    var size: Int64?

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        filename = c.nonEmptyString("filename")
        ext = c.nonEmptyString("ext")
        size = c.int64("size")
    }
}

struct LibraryFilePayload: Decodable, Sendable {
    var ino: String
    var metadata: FileMetadataPayload?
    var isSupplementary: Bool?
    var fileType: String?

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        guard let ino = c.nonEmptyString("ino") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "File without ino"))
        }
        self.ino = ino
        metadata = c.decode("metadata")
        isSupplementary = c.bool("isSupplementary")
        fileType = c.nonEmptyString("fileType")
    }

    var isPDF: Bool {
        metadata?.ext?.lowercased() == ".pdf" || metadata?.filename?.lowercased().hasSuffix(".pdf") == true
    }
}

struct AudioFilePayload: Decodable, Sendable {
    var index: Int?
    var ino: String
    var duration: Double
    var mimeType: String?
    var exclude: Bool
    var metadata: FileMetadataPayload?

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        guard let ino = c.nonEmptyString("ino") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Audio file without ino"))
        }
        self.ino = ino
        index = c.int("index")
        duration = c.double("duration") ?? 0
        mimeType = c.nonEmptyString("mimeType")
        exclude = c.bool("exclude") ?? false
        metadata = c.decode("metadata")
    }
}

/// Book `media.tracks[]`, episode `audioTrack` and play session `audioTracks[]`.
struct AudioTrackPayload: Decodable, Sendable {
    var index: Int?
    var ino: String?
    var startOffset: Double
    var duration: Double
    var contentURL: String?
    var mimeType: String?
    var metadata: FileMetadataPayload?

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        index = c.int("index")
        ino = c.nonEmptyString("ino")
        startOffset = c.double("startOffset") ?? 0
        duration = c.double("duration") ?? 0
        contentURL = c.nonEmptyString("contentUrl")
        mimeType = c.nonEmptyString("mimeType")
        metadata = c.decode("metadata")
    }

    /// The file inode, taken from the payload or the `…/file/{ino}` content URL.
    var resolvedIno: String? {
        if let ino {
            return ino
        }
        guard let contentURL, let range = contentURL.range(of: "/file/") else {
            return nil
        }
        let tail = contentURL[range.upperBound...]
        let ino = tail.prefix { $0 != "/" && $0 != "?" }
        return ino.isEmpty ? nil : String(ino)
    }
}

struct ChapterPayload: Decodable, Sendable {
    var id: Int?
    var start: Double
    var end: Double
    var title: String

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        guard let start = c.double("start") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Chapter without start"))
        }
        id = c.int("id")
        self.start = start
        end = c.double("end") ?? start
        title = c.string("title") ?? ""
    }
}

struct EpisodePayload: Decodable, Sendable {
    var id: String
    var libraryItemID: String?
    var libraryID: String?
    var index: Int?
    var season: String?
    var episode: String?
    var episodeType: String?
    var title: String?
    var subtitle: String?
    var description: String?
    var publishedAt: Date?
    var addedAt: Date?
    var duration: Double?
    var size: Int64?
    var chapters: [ChapterPayload]
    var audioFile: AudioFilePayload?
    var audioTrack: AudioTrackPayload?
    /// Present in `recent-episodes` responses.
    var podcast: MediaPayload?
    var enclosureLength: Int64?

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        guard let id = c.nonEmptyString("id") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Episode without id"))
        }
        self.id = id
        libraryItemID = c.nonEmptyString("libraryItemId")
        libraryID = c.nonEmptyString("libraryId")
        index = c.int("index")
        season = c.nonEmptyString("season")
        episode = c.nonEmptyString("episode")
        episodeType = c.nonEmptyString("episodeType")
        title = c.string("title")
        subtitle = c.nonEmptyString("subtitle")
        description = c.nonEmptyString("description")
        publishedAt = c.dateMS("publishedAt")
        addedAt = c.dateMS("addedAt")
        duration = c.double("duration")
        size = c.int64("size")
        chapters = c.array("chapters")
        audioFile = c.decode("audioFile")
        audioTrack = c.decode("audioTrack")
        podcast = c.decode("podcast")
        if let enclosure = c.decode("enclosure", as: EnclosurePayload.self) {
            enclosureLength = enclosure.length
        }
    }

    var resolvedDuration: Double {
        duration ?? audioTrack?.duration ?? audioFile?.duration ?? 0
    }

    var resolvedSize: Int64? {
        size ?? audioFile?.metadata?.size ?? enclosureLength
    }
}

struct EnclosurePayload: Decodable, Sendable {
    var length: Int64?

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        length = c.int64("length")
    }
}
