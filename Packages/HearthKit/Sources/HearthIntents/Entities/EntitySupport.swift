import AppIntents
import CoreSpotlight
import Foundation
import HearthData
import HearthModel
import UniformTypeIdentifiers

/// Conversion helpers shared by all entities.
enum EntitySupport {
    /// Strips HTML tags and collapses whitespace (descriptions are delivered as HTML by audiobookshelf).
    static func plainText(_ html: String?) -> String? {
        guard let html, !html.isEmpty else { return nil }
        var text = html.replacingOccurrences(of: "<br\\s*/?>|</p>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func releaseDate(_ released: String?) -> Date? {
        guard let released, let year = Int(released.prefix(4)), year > 0 else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: 1, day: 1))
    }

    /// The audiobookshelf web page of an item (Handoff, Spotlight, entity URL property).
    @MainActor
    static func webURL(_ id: ItemIdentifier) -> URL? {
        guard let client = try? HearthData.shared.connections.client(for: id.connectionID) else { return nil }
        return client.webURL(for: id)
    }

    /// `hearth://item/<id>`.
    static func deepLink(_ id: ItemIdentifier) -> URL? {
        var components = URLComponents()
        components.scheme = "hearth"
        components.host = "item"
        components.path = "/" + id.description
        return components.url
    }

    /// Cover data for entity thumbnails: the widget snapshot cover when available, else the image cache.
    @MainActor
    static func imageData(for id: ItemIdentifier, snapshotFile: String? = nil) async -> Data? {
        if let snapshotFile, let data = try? Data(contentsOf: SharedSnapshotStore.coverURL(snapshotFile)) {
            return data
        }
        return await HearthData.shared.images.imageData(for: id, size: .tiny)
    }

    /// Loads thumbnails for many items concurrently.
    @MainActor
    static func imageData(for ids: [ItemIdentifier]) async -> [ItemIdentifier: Data] {
        let images = HearthData.shared.images
        return await withTaskGroup(of: (ItemIdentifier, Data?).self) { group in
            for id in ids {
                group.addTask { (id, await images.imageData(for: id, size: .tiny)) }
            }
            var result = [ItemIdentifier: Data]()
            for await (id, data) in group {
                if let data {
                    result[id] = data
                }
            }
            return result
        }
    }

    static func displayImage(_ data: Data?, kind: ItemIdentifier.Kind) -> DisplayRepresentation.Image {
        if let data {
            return DisplayRepresentation.Image(data: data)
        }
        return DisplayRepresentation.Image(systemName: symbol(for: kind))
    }

    static func symbol(for kind: ItemIdentifier.Kind) -> String {
        switch kind {
        case .audiobook: "book"
        case .podcast: "antenna.radiowaves.left.and.right"
        case .episode: "play.square"
        case .series: "books.vertical"
        case .author: "person"
        case .narrator: "mic"
        case .collection: "rectangle.stack"
        case .playlist: "music.note.list"
        }
    }

    /// Spotlight attributes shared by all indexed entities.
    static func attributeSet(
        id: String,
        kind: ItemIdentifier.Kind,
        title: String,
        subtitle: String?,
        authors: [String],
        narrators: [String] = [],
        details: String?,
        genres: [String],
        addedAt: Date?,
        released: Date?,
        duration: TimeInterval?,
        webURL: URL?,
        imageData: Data?
    ) -> CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: kind == .audiobook || kind == .episode ? .audio : .content)
        attributes.title = title
        attributes.displayName = title
        attributes.contentDescription = subtitle ?? details
        attributes.artist = authors.first
        attributes.authorNames = authors
        attributes.performers = narrators
        attributes.genre = genres.first
        attributes.keywords = genres + authors + narrators + [subtitle].compactMap { $0 }
        attributes.contentCreationDate = released
        attributes.addedDate = addedAt
        attributes.thumbnailData = imageData
        attributes.url = webURL
        if let duration, duration > 0 {
            attributes.duration = NSNumber(value: duration)
        }
        attributes.relatedUniqueIdentifier = id
        attributes.domainIdentifier = kind.rawValue
        return attributes
    }
}

// MARK: - Listen Now / search sources

/// Data sources used by the entity queries. In the app they query `HearthData`; in the widget extension the
/// widget snapshot is preferred (cheap, no network) and `HearthData` is only used to resolve specific items.
@MainActor
enum EntitySource {
    /// Listen Now items as `(id, title, subtitle, coverFile)` without network access in the extension.
    struct Suggestion: Sendable {
        var id: ItemIdentifier
        var title: String
        var subtitle: String?
        var coverFile: String?
    }

    static func listenNowSuggestions() async -> [Suggestion] {
        let snapshot = SharedSnapshotStore.read()
        var entries = snapshot.listenNow
        if let nowPlaying = snapshot.nowPlaying, !entries.contains(where: { $0.id == nowPlaying.id }) {
            entries.insert(nowPlaying, at: 0)
        }
        if !entries.isEmpty || IntentSupport.isExtension {
            return entries.map { Suggestion(id: $0.id, title: $0.title, subtitle: $0.subtitle, coverFile: $0.coverFile) }
        }
        return await HearthData.shared.items.listenNow().map { item in
            Suggestion(id: item.id, title: item.name, subtitle: item.base.subtitleLine ?? item.base.authorLine, coverFile: nil)
        }
    }

    static func listenNowItems() async -> [AnyPlayableItem] {
        await HearthData.shared.items.listenNow()
    }

    static func search(_ query: String, downloadsOnly: Bool = false) async -> SearchResults {
        await HearthData.shared.items.search(query, scope: downloadsOnly ? .downloadsOnly : .everywhere)
    }

    /// Resolves items for `entities(for:)`; unknown items are skipped.
    static func items(_ identifiers: [String]) async -> [AnyItem] {
        var result = [AnyItem]()
        for string in identifiers {
            guard let id = ItemIdentifier(string) else { continue }
            if let item = try? await HearthData.shared.items.item(id) {
                result.append(item)
            }
        }
        return result
    }

    /// Snapshot entries for identifiers that couldn't be resolved (offline widget configuration).
    static func snapshotEntries(_ identifiers: [String]) -> [SharedSnapshot.Entry] {
        let snapshot = SharedSnapshotStore.read()
        let entries = snapshot.listenNow + [snapshot.nowPlaying].compactMap { $0 }
        return identifiers.compactMap { string in entries.first { $0.id.description == string } }
    }
}
