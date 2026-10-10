#if DEBUG
import Foundation
import HearthData
import HearthModel

/// Sample data for SwiftUI previews (DEBUG only).
public enum PreviewFixtures {
    public static let connectionID: ConnectionID = "preview-connection"
    public static let bookLibrary = LibraryIdentifier(connectionID: connectionID, libraryID: "books")
    public static let podcastLibrary = LibraryIdentifier(connectionID: connectionID, libraryID: "podcasts")

    public static func id(_ kind: ItemIdentifier.Kind, _ primary: String, library: LibraryIdentifier = bookLibrary, grouping: String? = nil) -> ItemIdentifier {
        ItemIdentifier(kind: kind, connectionID: library.connectionID, libraryID: library.libraryID, primaryID: primary, groupingID: grouping)
    }

    public static let connection = Connection(host: URL(string: "https://abs.example.com")!, username: "robin", serverVersion: "2.30.0")

    public static let libraries: [Library] = [
        Library(id: bookLibrary, name: "Audiobooks", mediaType: .audiobooks, displayOrder: 0, icon: "audiobookshelf"),
        Library(id: podcastLibrary, name: "Podcasts", mediaType: .podcasts, displayOrder: 1, icon: "podcast"),
    ]

    public static let audiobook = Audiobook(
        id: id(.audiobook, "book-1"),
        name: "The Hearth and the Hollow Hills",
        subtitle: "A Winter Tale",
        authors: ["Ada Lindqvist"],
        narrators: ["Moira Kent"],
        series: [SeriesFragment(id: "series-1", name: "Emberfall", sequence: "2")],
        descriptionHTML: "<p>Snow falls on the valley as the old fire keeper tells one last story.</p>",
        genres: ["Fantasy"],
        tags: ["Cozy"],
        addedAt: .now.addingTimeInterval(-86_400 * 3),
        released: "2021",
        explicit: false,
        abridged: false,
        duration: 11 * 3600 + 42 * 60
    )

    public static let audiobook2 = Audiobook(
        id: id(.audiobook, "book-2"),
        name: "Kindling",
        authors: ["Ada Lindqvist", "Jonas Berg"],
        narrators: ["Moira Kent"],
        series: [SeriesFragment(id: "series-1", name: "Emberfall", sequence: "1")],
        released: "2019",
        explicit: true,
        abridged: true,
        duration: 8 * 3600 + 5 * 60
    )

    public static let audiobooks: [Audiobook] = [audiobook, audiobook2] + (3...8).map(makeAudiobook)

    private static func makeAudiobook(_ index: Int) -> Audiobook {
        let duration: TimeInterval = Double(index) * 3600
        return Audiobook(id: id(.audiobook, "book-\(index)"), name: "Sample Book \(index)", authors: ["Author \(index)"], released: "20\(10 + index)", duration: duration)
    }

    public static let series = Series(id: id(.series, "series-1"), name: "Emberfall", audiobooks: [audiobook2, audiobook], totalDuration: 20 * 3600)
    public static let seriesLarge = Series(id: id(.series, "series-2"), name: "The Long Night Cycle", audiobooks: Array(audiobooks.prefix(5)), totalDuration: 52 * 3600)

    public static let author = Person(id: id(.author, "author-1"), name: "Ada Lindqvist", bookCount: 7, hasImage: true)
    public static let narrator = Person(id: id(.narrator, "Moira Kent"), name: "Moira Kent", bookCount: 12)

    public static let podcast = Podcast(
        id: id(.podcast, "podcast-1", library: podcastLibrary),
        name: "Fireside Chats",
        authors: ["Hearth Radio"],
        descriptionHTML: "Conversations by the fire.",
        episodeCount: 120,
        incompleteEpisodeCount: 4
    )

    public static let episode = Episode(
        id: id(.episode, "episode-1", library: podcastLibrary, grouping: "podcast-1"),
        name: "Why We Gather Around Fires",
        podcastName: "Fireside Chats",
        authors: ["Hearth Radio"],
        descriptionHTML: "<p>From prehistory to today: what the fire place means to us, and why stories sound better by its light.</p>",
        publishedAt: .now.addingTimeInterval(-86_400 * 2),
        season: "3",
        episode: "12",
        type: .full,
        duration: 52 * 60
    )

    public static let episodes: [Episode] = [episode] + (2...6).map(makeEpisode)

    private static func makeEpisode(_ index: Int) -> Episode {
        let age: TimeInterval = -86_400 * Double(index * 4)
        let duration: TimeInterval = Double(20 + index * 5) * 60
        let type: Episode.EpisodeType = index == 6 ? .trailer : .full
        return Episode(
            id: id(.episode, "episode-\(index)", library: podcastLibrary, grouping: "podcast-1"),
            name: "Episode \(index)",
            podcastName: "Fireside Chats",
            descriptionHTML: "Episode description \(index).",
            publishedAt: Date.now.addingTimeInterval(age),
            type: type,
            duration: duration
        )
    }

    public static let collection = ItemCollection(
        id: id(.collection, "collection-1"),
        name: "Winter Evenings",
        descriptionHTML: "Long books for long nights.",
        items: audiobooks.prefix(5).map { .audiobook($0) }
    )

    public static let homeRows: [HomeRow] = [
        HomeRow(id: "continue-listening", label: "Continue Listening", items: audiobooks.prefix(3).map { .audiobook($0) }),
        HomeRow(id: "recently-added", label: "Recently Added", items: audiobooks.map { .audiobook($0) }),
        HomeRow(id: "recent-series", label: "Recent Series", items: [.series(series), .series(seriesLarge)]),
    ]

    public static let progress = ProgressEntity(id: "progress-1", itemID: audiobook.id, progress: 0.42, duration: audiobook.duration, currentTime: audiobook.duration * 0.42, startedAt: .now.addingTimeInterval(-86_400), lastUpdate: .now, finishedAt: nil)
}
#endif
