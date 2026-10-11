import AppIntents
import CoreSpotlight
import Foundation
import HearthData
import HearthModel

/// The kind of an item, exposed to Shortcuts.
public enum ItemKind: String, AppEnum {
    case audiobook
    case podcast
    case episode
    case series
    case author
    case narrator
    case collection
    case playlist

    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("Item Type", table: "System"))
    public static let caseDisplayRepresentations: [ItemKind: DisplayRepresentation] = [
        .audiobook: DisplayRepresentation(title: LocalizedStringResource("Audiobook", table: "System"), image: .init(systemName: "book")),
        .podcast: DisplayRepresentation(title: LocalizedStringResource("Podcast", table: "System"), image: .init(systemName: "antenna.radiowaves.left.and.right")),
        .episode: DisplayRepresentation(title: LocalizedStringResource("Episode", table: "System"), image: .init(systemName: "play.square")),
        .series: DisplayRepresentation(title: LocalizedStringResource("Series", table: "System"), image: .init(systemName: "books.vertical")),
        .author: DisplayRepresentation(title: LocalizedStringResource("Author", table: "System"), image: .init(systemName: "person")),
        .narrator: DisplayRepresentation(title: LocalizedStringResource("Narrator", table: "System"), image: .init(systemName: "mic")),
        .collection: DisplayRepresentation(title: LocalizedStringResource("Collection", table: "System"), image: .init(systemName: "rectangle.stack")),
        .playlist: DisplayRepresentation(title: LocalizedStringResource("Playlist", table: "System"), image: .init(systemName: "music.note.list")),
    ]

    init(_ kind: ItemIdentifier.Kind) {
        self = ItemKind(rawValue: kind.rawValue) ?? .audiobook
    }
}

/// Any audiobookshelf item: audiobooks, podcasts, episodes, series, authors, narrators, collections and playlists.
public struct ItemEntity: IndexedEntity {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("Item", table: "System"))
    public static let defaultQuery = ItemEntityQuery()

    /// `ItemIdentifier.description`.
    public let id: String

    @Property(title: LocalizedStringResource("Title", table: "System"))
    public var title: String

    @Property(title: LocalizedStringResource("Kind", table: "System"))
    public var kind: ItemKind

    @Property(title: LocalizedStringResource("Authors", table: "System"))
    public var authors: [String]

    @Property(title: LocalizedStringResource("Description", table: "System"))
    public var details: String?

    @Property(title: LocalizedStringResource("Genres", table: "System"))
    public var genres: [String]

    @Property(title: LocalizedStringResource("Date Added", table: "System"))
    public var addedAt: Date?

    @Property(title: LocalizedStringResource("Release Date", table: "System"))
    public var releaseDate: Date?

    @Property(title: LocalizedStringResource("Web Page", table: "System"))
    public var url: URL?

    /// Secondary line (series, podcast, authors).
    public var subtitle: String?
    /// Small cover (JPEG/PNG) used for the thumbnail.
    public var imageData: Data?

    public var itemID: ItemIdentifier? { ItemIdentifier(id) }

    public var displayRepresentation: DisplayRepresentation {
        let secondary = subtitle ?? (authors.isEmpty ? nil : authors.formatted(.list(type: .and, width: .short)))
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: secondary.map { "\($0)" },
            image: EntitySupport.displayImage(imageData, kind: ItemIdentifier(id)?.kind ?? .audiobook)
        )
    }

    public var attributeSet: CSSearchableItemAttributeSet {
        EntitySupport.attributeSet(
            id: id,
            kind: ItemIdentifier(id)?.kind ?? .audiobook,
            title: title,
            subtitle: subtitle,
            authors: authors,
            details: details,
            genres: genres,
            addedAt: addedAt,
            released: releaseDate,
            duration: nil,
            webURL: url,
            imageData: imageData
        )
    }

    public init(id: ItemIdentifier, title: String, subtitle: String? = nil, authors: [String] = [], details: String? = nil, genres: [String] = [], addedAt: Date? = nil, releaseDate: Date? = nil, url: URL? = nil, imageData: Data? = nil) {
        self.id = id.description
        self.subtitle = subtitle
        self.imageData = imageData
        self.title = title
        self.kind = ItemKind(id.kind)
        self.authors = authors
        self.details = details
        self.genres = genres
        self.addedAt = addedAt
        self.releaseDate = releaseDate
        self.url = url
    }

    @MainActor
    public init(_ item: AnyItem, imageData: Data? = nil) {
        let base = item.base
        let subtitle: String? = switch item {
        case .audiobook(let audiobook): audiobook.subtitleLine ?? audiobook.authorLine
        case .episode(let episode): episode.podcastName
        case .podcast(let podcast): podcast.authorLine
        case .series(let series): series.authorLine
        case .person, .collection: nil
        }
        let added = base.addedAt
        let released: Date? = if case .episode(let episode) = item { episode.publishedAt } else { EntitySupport.releaseDate(base.released) }
        self.init(
            id: item.id,
            title: item.name,
            subtitle: subtitle,
            authors: base.authors,
            details: EntitySupport.plainText(base.descriptionHTML),
            genres: base.genres,
            addedAt: added,
            releaseDate: released,
            url: EntitySupport.webURL(item.id),
            imageData: imageData
        )
    }

    @MainActor
    public init(_ item: AnyPlayableItem, imageData: Data? = nil) {
        self.init(AnyItem(item), imageData: imageData)
    }

    init(_ suggestion: EntitySource.Suggestion, imageData: Data?) {
        self.init(id: suggestion.id, title: suggestion.title, subtitle: suggestion.subtitle, imageData: imageData)
    }

    init(_ entry: SharedSnapshot.Entry) {
        let data = entry.coverFile.flatMap { try? Data(contentsOf: SharedSnapshotStore.coverURL($0)) }
        self.init(id: entry.id, title: entry.title, subtitle: entry.subtitle, imageData: data)
    }
}

public struct ItemEntityQuery: EntityStringQuery {
    public init() {}

    @MainActor
    public func entities(for identifiers: [String]) async throws -> [ItemEntity] {
        let items = await EntitySource.items(identifiers)
        let images = await EntitySupport.imageData(for: items.map(\.id))
        var entities = items.map { ItemEntity($0, imageData: images[$0.id]) }
        let missing = identifiers.filter { id in !entities.contains { $0.id == id } }
        entities += EntitySource.snapshotEntries(missing).map(ItemEntity.init)
        return entities
    }

    @MainActor
    public func entities(matching string: String) async throws -> [ItemEntity] {
        let results = await EntitySource.search(string)
        var items = [AnyItem]()
        items += results.audiobooks.map(AnyItem.audiobook)
        items += results.podcasts.map(AnyItem.podcast)
        items += results.episodes.map(AnyItem.episode)
        items += results.series.map(AnyItem.series)
        items += results.authors.map(AnyItem.person)
        items += results.narrators.map(AnyItem.person)
        items = Array(items.prefix(40))
        let images = await EntitySupport.imageData(for: items.map(\.id))
        return items.map { ItemEntity($0, imageData: images[$0.id]) }
    }

    @MainActor
    public func suggestedEntities() async throws -> [ItemEntity] {
        var entities = [ItemEntity]()
        for suggestion in await EntitySource.listenNowSuggestions() {
            entities.append(ItemEntity(suggestion, imageData: await EntitySupport.imageData(for: suggestion.id, snapshotFile: suggestion.coverFile)))
        }
        return entities
    }
}
