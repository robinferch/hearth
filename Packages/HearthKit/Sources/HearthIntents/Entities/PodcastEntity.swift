import AppIntents
import CoreSpotlight
import Foundation
import HearthData
import HearthModel

/// A podcast.
public struct PodcastEntity: IndexedEntity {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("Podcast", table: "System"))
    public static let defaultQuery = PodcastEntityQuery()

    public let id: String

    @Property(title: LocalizedStringResource("Title", table: "System"))
    public var title: String

    @Property(title: LocalizedStringResource("Authors", table: "System"))
    public var authors: [String]

    @Property(title: LocalizedStringResource("Description", table: "System"))
    public var details: String?

    @Property(title: LocalizedStringResource("Genres", table: "System"))
    public var genres: [String]

    @Property(title: LocalizedStringResource("Episodes", table: "System"))
    public var episodeCount: Int

    @Property(title: LocalizedStringResource("Unplayed Episodes", table: "System"))
    public var unplayedEpisodeCount: Int?

    @Property(title: LocalizedStringResource("Explicit", table: "System"))
    public var isExplicit: Bool

    @Property(title: LocalizedStringResource("Web Page", table: "System"))
    public var url: URL?

    public var addedAt: Date?
    public var imageData: Data?

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: authors.isEmpty ? nil : "\(authors.formatted(.list(type: .and, width: .short)))",
            image: EntitySupport.displayImage(imageData, kind: .podcast)
        )
    }

    public var attributeSet: CSSearchableItemAttributeSet {
        EntitySupport.attributeSet(
            id: id,
            kind: .podcast,
            title: title,
            subtitle: authors.first,
            authors: authors,
            details: details,
            genres: genres,
            addedAt: addedAt,
            released: nil,
            duration: nil,
            webURL: url,
            imageData: imageData
        )
    }

    @MainActor
    public init(_ podcast: Podcast, imageData: Data? = nil) {
        id = podcast.id.description
        addedAt = podcast.addedAt
        self.imageData = imageData
        title = podcast.name
        authors = podcast.authors
        details = EntitySupport.plainText(podcast.descriptionHTML)
        genres = podcast.genres
        episodeCount = podcast.episodeCount
        unplayedEpisodeCount = podcast.incompleteEpisodeCount
        isExplicit = podcast.explicit
        url = EntitySupport.webURL(podcast.id)
    }

    init(id: ItemIdentifier, title: String, author: String?, imageData: Data?) {
        self.id = id.description
        self.imageData = imageData
        self.title = title
        authors = author.map { [$0] } ?? []
        details = nil
        genres = []
        episodeCount = 0
        unplayedEpisodeCount = nil
        isExplicit = false
        url = nil
    }
}

public struct PodcastEntityQuery: EntityStringQuery {
    public init() {}

    @MainActor
    public func entities(for identifiers: [String]) async throws -> [PodcastEntity] {
        let podcasts = await EntitySource.items(identifiers).compactMap { item -> Podcast? in
            if case .podcast(let podcast) = item { podcast } else { nil }
        }
        let images = await EntitySupport.imageData(for: podcasts.map(\.id))
        return podcasts.map { PodcastEntity($0, imageData: images[$0.id]) }
    }

    @MainActor
    public func entities(matching string: String) async throws -> [PodcastEntity] {
        let podcasts = Array(await EntitySource.search(string).podcasts.prefix(30))
        let images = await EntitySupport.imageData(for: podcasts.map(\.id))
        return podcasts.map { PodcastEntity($0, imageData: images[$0.id]) }
    }

    /// Podcasts of in-progress episodes, then downloaded podcasts.
    @MainActor
    public func suggestedEntities() async throws -> [PodcastEntity] {
        var ids = [ItemIdentifier]()
        for suggestion in await EntitySource.listenNowSuggestions() {
            if let podcast = suggestion.id.podcastIdentifier, !ids.contains(podcast) {
                ids.append(podcast)
            }
        }
        if !IntentSupport.isExtension {
            for podcast in HearthData.shared.downloads.downloadedPodcasts() where !ids.contains(podcast.id) {
                ids.append(podcast.id)
            }
        }
        return try await entities(for: ids.prefix(12).map(\.description))
    }
}

/// A podcast episode.
public struct EpisodeEntity: IndexedEntity {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("Episode", table: "System"))
    public static let defaultQuery = EpisodeEntityQuery()

    public let id: String

    @Property(title: LocalizedStringResource("Title", table: "System"))
    public var title: String

    @Property(title: LocalizedStringResource("Podcast", table: "System"))
    public var podcastName: String

    @Property(title: LocalizedStringResource("Description", table: "System"))
    public var details: String?

    @Property(title: LocalizedStringResource("Release Date", table: "System"))
    public var releaseDate: Date?

    @Property(title: LocalizedStringResource("Duration", table: "System"))
    public var duration: Measurement<UnitDuration>?

    public var authors: [String] = []
    public var imageData: Data?

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(podcastName)",
            image: EntitySupport.displayImage(imageData, kind: .episode)
        )
    }

    public var attributeSet: CSSearchableItemAttributeSet {
        EntitySupport.attributeSet(
            id: id,
            kind: .episode,
            title: title,
            subtitle: podcastName,
            authors: authors,
            details: details,
            genres: [],
            addedAt: nil,
            released: releaseDate,
            duration: duration?.converted(to: .seconds).value,
            webURL: nil,
            imageData: imageData
        )
    }

    public init(_ episode: Episode, imageData: Data? = nil) {
        id = episode.id.description
        authors = episode.authors
        self.imageData = imageData
        title = episode.name
        podcastName = episode.podcastName
        details = EntitySupport.plainText(episode.descriptionHTML)
        releaseDate = episode.publishedAt
        duration = episode.duration > 0 ? Measurement(value: episode.duration, unit: .seconds) : nil
    }

    init(id: ItemIdentifier, title: String, podcastName: String?, imageData: Data?) {
        self.id = id.description
        self.imageData = imageData
        self.title = title
        self.podcastName = podcastName ?? ""
        details = nil
        releaseDate = nil
        duration = nil
    }
}

public struct EpisodeEntityQuery: EntityStringQuery {
    public init() {}

    @MainActor
    public func entities(for identifiers: [String]) async throws -> [EpisodeEntity] {
        let episodes = await EntitySource.items(identifiers).compactMap { item -> Episode? in
            if case .episode(let episode) = item { episode } else { nil }
        }
        let images = await EntitySupport.imageData(for: episodes.map(\.id))
        var entities = episodes.map { EpisodeEntity($0, imageData: images[$0.id]) }
        let missing = identifiers.filter { id in !entities.contains { $0.id == id } }
        for entry in EntitySource.snapshotEntries(missing) where entry.id.kind == .episode {
            let data = entry.coverFile.flatMap { try? Data(contentsOf: SharedSnapshotStore.coverURL($0)) }
            entities.append(EpisodeEntity(id: entry.id, title: entry.title, podcastName: entry.subtitle, imageData: data))
        }
        return entities
    }

    @MainActor
    public func entities(matching string: String) async throws -> [EpisodeEntity] {
        let episodes = Array(await EntitySource.search(string).episodes.prefix(30))
        let images = await EntitySupport.imageData(for: episodes.map(\.id))
        return episodes.map { EpisodeEntity($0, imageData: images[$0.id]) }
    }

    @MainActor
    public func suggestedEntities() async throws -> [EpisodeEntity] {
        var entities = [EpisodeEntity]()
        for suggestion in await EntitySource.listenNowSuggestions() where suggestion.id.kind == .episode {
            let data = await EntitySupport.imageData(for: suggestion.id, snapshotFile: suggestion.coverFile)
            entities.append(EpisodeEntity(id: suggestion.id, title: suggestion.title, podcastName: suggestion.subtitle, imageData: data))
        }
        return entities
    }
}
