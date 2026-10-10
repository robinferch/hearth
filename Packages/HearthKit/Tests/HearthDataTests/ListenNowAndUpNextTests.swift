import Foundation
@testable import HearthData
import HearthAPI
import HearthModel
import Testing

@Suite("Listen Now")
struct ListenNowPlannerTests {
    @Test func ordersNewestFirstAndFilters() {
        let a = Fixtures.bookID("a", connection: "c1")
        let b = Fixtures.bookID("b", connection: "c2")
        let hidden = Fixtures.bookID("h", connection: "c1")
        let finished = Fixtures.bookID("f", connection: "c1")
        let unknown = Fixtures.bookID("u", connection: "gone")
        let series = ItemIdentifier(kind: .series, connectionID: "c1", libraryID: "books", primaryID: "s")
        let progress = [
            Fixtures.progress(a, currentTime: 10, lastUpdate: Fixtures.date(10)),
            Fixtures.progress(b, currentTime: 10, lastUpdate: Fixtures.date(20)),
            Fixtures.progress(hidden, currentTime: 10, lastUpdate: Fixtures.date(30), hidden: true),
            Fixtures.progress(finished, currentTime: 100, lastUpdate: Fixtures.date(40)),
            Fixtures.progress(unknown, currentTime: 10, lastUpdate: Fixtures.date(50)),
            Fixtures.progress(series, currentTime: 10, lastUpdate: Fixtures.date(60)),
        ]
        let online = ListenNowPlanner.order(progress, connections: ["c1", "c2"], offline: false, isDownloaded: { _ in false })
        #expect(online == [b, a])

        let offline = ListenNowPlanner.order(progress, connections: ["c1", "c2"], offline: true, isDownloaded: { $0 == a })
        #expect(offline == [a])
    }

    @MainActor
    @Test func repositoryResolvesItemsInOrder() async {
        let client = MockClient(connection: Fixtures.connection())
        let id = client.connection.id
        let first = Fixtures.book("first", connection: id)
        let second = Fixtures.book("second", connection: id)
        client.update {
            $0.audiobooks = ["first": first, "second": second]
        }
        let hearth = makeHearth([client])
        await hearth.progress.update(second.id, currentTime: 10, duration: 100)
        await hearth.progress.update(first.id, currentTime: 10, duration: 100)
        // Unknown on the server: dropped.
        await hearth.progress.update(Fixtures.bookID("missing", connection: id), currentTime: 10, duration: 100)

        let items = await hearth.items.listenNow()
        #expect(items.map(\.id) == [first.id, second.id])
    }

    @MainActor
    @Test func itemLookupFallsBackToCacheWhenServerFails() async throws {
        let client = MockClient(connection: Fixtures.connection())
        let book = Fixtures.book("b", connection: client.connection.id)
        client.update { $0.audiobooks = ["b": book] }
        let hearth = makeHearth([client])
        _ = try await hearth.items.item(book.id)

        client.update { $0.failAll = true }
        #expect(try await hearth.items.playable(book.id).id == book.id)
        await #expect(throws: (any Error).self) {
            try await hearth.items.item(Fixtures.bookID("unknown", connection: client.connection.id))
        }
    }
}

@Suite("Up Next")
struct UpNextTests {
    let connection = "conn"

    @Test func sourcePrefersOriginThenPodcastThenSeries() {
        let series = ItemIdentifier(kind: .series, connectionID: connection, libraryID: "books", primaryID: "s1")
        let book = AnyPlayableItem.audiobook(Fixtures.book("b", connection: connection, series: [SeriesFragment(id: "s1", name: "S", sequence: "1")]))
        let collection = ItemIdentifier(kind: .collection, connectionID: connection, libraryID: "books", primaryID: "c")

        #expect(UpNextPlanner.source(origin: .collection(collection), item: book) { _ in .default } == .collection(collection))
        #expect(UpNextPlanner.source(origin: .none, item: book) { _ in .default } == .series(series))
        #expect(UpNextPlanner.source(origin: .none, item: book) { _ in .disabled } == .none)
        #expect(UpNextPlanner.source(origin: .none, item: book) { _ in .listenNow } == .listenNow)
        #expect(UpNextPlanner.source(origin: .listenNow, item: book) { _ in .disabled } == .listenNow)

        let episode = AnyPlayableItem.episode(Fixtures.episode("e", podcast: "pod", connection: connection))
        let podcast = ItemIdentifier(kind: .podcast, connectionID: connection, libraryID: "pods", primaryID: "pod")
        #expect(UpNextPlanner.source(origin: .carPlay, item: episode) { _ in .default } == .podcast(podcast))
    }

    @Test func followingSkipsFinishedAndEarlierItems() {
        let books = (1...5).map { AnyPlayableItem.audiobook(Fixtures.book("b\($0)", connection: connection)) }
        let finished: Set<String> = ["b4"]
        let next = UpNextPlanner.following(books[1].id, in: books) { finished.contains($0.primaryID) }
        #expect(next.map(\.id.primaryID) == ["b3", "b5"])

        let notInList = UpNextPlanner.following(Fixtures.bookID("x", connection: connection), in: books) { finished.contains($0.primaryID) }
        #expect(notInList.map(\.id.primaryID) == ["b1", "b2", "b3", "b5"])

        #expect(UpNextPlanner.firstUnfinished(in: books) { $0.primaryID == "b1" }?.id.primaryID == "b2")
        #expect(UpNextPlanner.firstUnfinished(in: books) { _ in true }?.id.primaryID == "b1")
    }

    @MainActor
    @Test func repositoryUsesSeriesOrder() async throws {
        let client = MockClient(connection: Fixtures.connection())
        let id = client.connection.id
        let fragment = SeriesFragment(id: "s1", name: "Saga", sequence: nil)
        let books = (1...4).map { Fixtures.book("b\($0)", connection: id, series: [fragment]) }
        client.update {
            $0.seriesBooks = ["s1": books]
            $0.audiobooks = Dictionary(uniqueKeysWithValues: books.map { ($0.id.primaryID, $0) })
        }
        let hearth = makeHearth([client])
        try await hearth.progress.setFinished(books[2].id, finished: true)

        let next = await hearth.items.upNext(after: books[0].id, origin: .none)
        #expect(next.map(\.id.primaryID) == ["b2", "b4"])

        let series = ItemIdentifier(kind: .series, connectionID: id, libraryID: "books", primaryID: "s1")
        hearth.itemSettings.setUpNextStrategy(.disabled, for: series)
        #expect(await hearth.items.upNext(after: books[0].id, origin: .none).isEmpty)

        try await hearth.progress.setFinished(books[0].id, finished: true)
        #expect(try await hearth.items.firstPlayable(in: series).id.primaryID == "b2")
    }

    @MainActor
    @Test func repositoryUsesPodcastEpisodeSettings() async throws {
        let client = MockClient(connection: Fixtures.connection())
        let id = client.connection.id
        let podcastID = ItemIdentifier(kind: .podcast, connectionID: id, libraryID: "pods", primaryID: "pod")
        let episodes = (1...4).map { Fixtures.episode("e\($0)", podcast: "pod", connection: id, published: Fixtures.date(Double($0) * 100)) }
        client.update { $0.podcasts = ["pod": (Podcast(id: podcastID, name: "Pod"), episodes)] }
        let hearth = makeHearth([client])
        hearth.itemSettings.setEpisodeListSettings(EpisodeListSettings(sort: .released, direction: .descending), for: podcastID)
        try await hearth.progress.setFinished(episodes[1].id, finished: true)

        let next = await hearth.items.upNext(after: episodes[3].id, origin: .podcast(podcastID))
        #expect(next.map(\.id.primaryID) == ["e3", "e1"])
        #expect(try await hearth.items.firstPlayable(in: podcastID).id.primaryID == "e4")
    }
}
