import AppIntents
import CoreSpotlight
import Foundation
import HearthData
import HearthModel

/// An audiobook, using the system books schema so Siri / Apple Intelligence understand it.
@AppEntity(schema: .books.audiobook)
public struct AudiobookEntity: IndexedEntity {
    public static let defaultQuery = AudiobookEntityQuery()

    /// `ItemIdentifier.description`.
    public let id: String

    // Schema properties.
    public var title: String?
    public var seriesTitle: String?
    public var author: String?
    public var genre: String?
    public var purchaseDate: Date?
    public var webLink: URL?
    /// Deep link into Hearth (`hearth://item/<id>`).
    public var url: URL?

    // Hearth additions.
    @Property(title: LocalizedStringResource("Narrators", table: "System"))
    public var narrators: [String]

    @Property(title: LocalizedStringResource("Authors", table: "System"))
    public var authors: [String]

    @Property(title: LocalizedStringResource("Description", table: "System"))
    public var details: String?

    @Property(title: LocalizedStringResource("Release Date", table: "System"))
    public var releaseDate: Date?

    @Property(title: LocalizedStringResource("Explicit", table: "System"))
    public var isExplicit: Bool

    @Property(title: LocalizedStringResource("Abridged", table: "System"))
    public var isAbridged: Bool

    public var genres: [String] = []
    public var duration: TimeInterval = 0
    public var imageData: Data?

    public var displayRepresentation: DisplayRepresentation {
        let subtitle = seriesTitle ?? author
        return DisplayRepresentation(
            title: "\(title ?? "")",
            subtitle: subtitle.map { "\($0)" },
            image: EntitySupport.displayImage(imageData, kind: .audiobook)
        )
    }

    public var attributeSet: CSSearchableItemAttributeSet {
        EntitySupport.attributeSet(
            id: id,
            kind: .audiobook,
            title: title ?? "",
            subtitle: seriesTitle,
            authors: authors,
            narrators: narrators,
            details: details,
            genres: genres,
            addedAt: purchaseDate,
            released: releaseDate,
            duration: duration,
            webURL: webLink,
            imageData: imageData
        )
    }

    @MainActor
    public init(_ audiobook: Audiobook, imageData: Data? = nil) {
        id = audiobook.id.description
        title = audiobook.name
        seriesTitle = audiobook.series.first?.formatted
        author = audiobook.authorLine
        genre = audiobook.genres.first
        purchaseDate = audiobook.addedAt
        webLink = EntitySupport.webURL(audiobook.id)
        url = EntitySupport.deepLink(audiobook.id)
        genres = audiobook.genres
        duration = audiobook.duration
        self.imageData = imageData
        narrators = audiobook.narrators
        authors = audiobook.authors
        details = EntitySupport.plainText(audiobook.descriptionHTML)
        releaseDate = EntitySupport.releaseDate(audiobook.released)
        isExplicit = audiobook.explicit
        isAbridged = audiobook.abridged
    }

    init(id: ItemIdentifier, title: String, author: String?, imageData: Data?) {
        self.id = id.description
        self.title = title
        self.author = author
        url = EntitySupport.deepLink(id)
        self.imageData = imageData
        narrators = []
        authors = author.map { [$0] } ?? []
        details = nil
        releaseDate = nil
        isExplicit = false
        isAbridged = false
    }
}

public struct AudiobookEntityQuery: EntityStringQuery {
    public init() {}

    @MainActor
    public func entities(for identifiers: [String]) async throws -> [AudiobookEntity] {
        let books = await EntitySource.items(identifiers).compactMap { item -> Audiobook? in
            if case .audiobook(let audiobook) = item { audiobook } else { nil }
        }
        let images = await EntitySupport.imageData(for: books.map(\.id))
        var entities = books.map { AudiobookEntity($0, imageData: images[$0.id]) }
        let missing = identifiers.filter { id in !entities.contains { $0.id == id } }
        for entry in EntitySource.snapshotEntries(missing) where entry.id.kind == .audiobook {
            let data = entry.coverFile.flatMap { try? Data(contentsOf: SharedSnapshotStore.coverURL($0)) }
            entities.append(AudiobookEntity(id: entry.id, title: entry.title, author: entry.subtitle, imageData: data))
        }
        return entities
    }

    @MainActor
    public func entities(matching string: String) async throws -> [AudiobookEntity] {
        let books = Array(await EntitySource.search(string).audiobooks.prefix(30))
        let images = await EntitySupport.imageData(for: books.map(\.id))
        return books.map { AudiobookEntity($0, imageData: images[$0.id]) }
    }

    @MainActor
    public func suggestedEntities() async throws -> [AudiobookEntity] {
        var entities = [AudiobookEntity]()
        for suggestion in await EntitySource.listenNowSuggestions() where suggestion.id.kind == .audiobook {
            let data = await EntitySupport.imageData(for: suggestion.id, snapshotFile: suggestion.coverFile)
            entities.append(AudiobookEntity(id: suggestion.id, title: suggestion.title, author: suggestion.subtitle, imageData: data))
        }
        return entities
    }
}
