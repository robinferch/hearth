import Foundation
@testable import HearthData
import HearthAPI
import HearthModel
import Testing

@Suite("Search ranking")
struct SearchRankerTests {
    let connection = "conn"

    @Test func normalizesDiacriticsAndPunctuation() {
        #expect(SearchRanker.normalize("  Der Herr  der Ringe: Die Gefährten! ") == "der herr der ringe die gefahrten")
    }

    @Test func ranksExactPrefixSubstringFuzzy() {
        let names = ["The Hobbit and friends", "Hobbit", "A Hobbit Story", "Hobbitses", "Harry Potter"]
        let books = names.enumerated().map { Fixtures.book("b\($0.offset)", connection: connection, name: $0.element) }
        let ranked = SearchRanker.rank(books, query: "hobbit", id: \.id, name: \.name).map(\.name)
        #expect(ranked.first == "Hobbit")
        #expect(ranked.last == "Harry Potter")
        #expect(ranked.firstIndex(of: "Hobbitses")! < ranked.firstIndex(of: "A Hobbit Story")!)
    }

    @Test func toleratesTypos() {
        let books = [
            Fixtures.book("1", connection: connection, name: "Project Hail Mary"),
            Fixtures.book("2", connection: connection, name: "Mistborn"),
        ]
        #expect(SearchRanker.rank(books, query: "projekt hail", id: \.id, name: \.name).first?.name == "Project Hail Mary")
    }

    @Test func titleMatchesBeatAuthorMatches() {
        let byAuthor = Fixtures.book("1", connection: connection, name: "Elantris", authors: ["Brandon Sanderson"])
        let byTitle = Fixtures.book("2", connection: connection, name: "Sanderson's Guide", authors: ["Someone"])
        let ranked = SearchRanker.rank([byAuthor, byTitle], query: "sanderson", id: \.id, name: \.name, secondary: \.authors)
        #expect(ranked.map(\.id.primaryID) == ["2", "1"])
    }

    @Test func deduplicatesByIdentifier() {
        let book = Fixtures.book("1", connection: connection, name: "Dune")
        #expect(SearchRanker.rank([book, book], query: "dune", id: \.id, name: \.name).count == 1)
    }

    @MainActor
    @Test func repositorySearchesAllLibrariesAndRanks() async {
        let c1 = MockClient(connection: Fixtures.connection("alice"))
        let c2 = MockClient(connection: Fixtures.connection("bob"))
        let lib1 = Library(id: LibraryIdentifier(connectionID: c1.connection.id, libraryID: "books"), name: "Books", mediaType: .audiobooks, displayOrder: 0)
        let lib2 = Library(id: LibraryIdentifier(connectionID: c2.connection.id, libraryID: "books"), name: "Books", mediaType: .audiobooks, displayOrder: 0)
        c1.update {
            $0.libraries = [lib1]
            $0.searchResults = ["books": SearchResults(audiobooks: [Fixtures.book("x", connection: c1.connection.id, name: "Dune Messiah")])]
        }
        c2.update {
            $0.libraries = [lib2]
            $0.searchResults = ["books": SearchResults(audiobooks: [Fixtures.book("y", connection: c2.connection.id, name: "Dune")])]
        }
        let hearth = makeHearth([c1, c2])
        await hearth.connections.reloadLibraries()

        let everywhere = await hearth.items.search("dune", scope: .everywhere)
        #expect(everywhere.audiobooks.map(\.name) == ["Dune", "Dune Messiah"])

        let scoped = await hearth.items.search("dune", scope: .library(lib1.id))
        #expect(scoped.audiobooks.map(\.name) == ["Dune Messiah"])
        #expect(await hearth.items.search("dune", scope: .downloadsOnly).isEmpty)
    }
}

@Suite("Dominant color")
struct DominantColorTests {
    func pixels(_ colors: [(UInt8, UInt8, UInt8, Int)]) -> (pixels: [UInt8], count: Int) {
        var result = [UInt8]()
        for (r, g, b, count) in colors {
            for _ in 0..<count {
                result += [r, g, b, 255]
            }
        }
        return (result, result.count / 4)
    }

    @Test func solidColor() throws {
        let (data, count) = pixels([(255, 0, 0, 100)])
        let color = try #require(DominantColor.compute(rgba: data, count: count))
        #expect(color.red > 0.99 && color.green < 0.01 && color.blue < 0.01)
    }

    @Test func saturatedAccentBeatsGreyMajority() throws {
        let (data, count) = pixels([(128, 128, 128, 80), (20, 60, 220, 20)])
        let color = try #require(DominantColor.compute(rgba: data, count: count))
        #expect(color.blue > color.red && color.blue > color.green)
    }

    @Test func greyImageFallsBackToAverage() throws {
        let (data, count) = pixels([(100, 100, 100, 50), (200, 200, 200, 50)])
        let color = try #require(DominantColor.compute(rgba: data, count: count))
        #expect(abs(color.red - 150.0 / 255) < 0.01)
        #expect(abs(color.red - color.blue) < 0.001)
    }

    @Test func luminance() {
        #expect(RGBColor(red: 1, green: 1, blue: 1).isLight)
        #expect(!RGBColor(red: 0.1, green: 0.1, blue: 0.3).isLight)
    }
}

@Suite("Support")
struct SupportTests {
    @Test func lruEvictsLeastRecentlyUsed() {
        var cache = LRUCache<Int, String>(capacity: 10)
        for index in 0..<10 {
            cache.set("\(index)", for: index)
        }
        _ = cache.value(for: 0)
        cache.set("10", for: 10)
        #expect(cache.peek(0) == "0")
        #expect(cache.peek(1) == nil)
        #expect(cache.count <= 10)
    }

    @Test func storageKeyIgnoresKindAndLibrary() {
        let a = ItemIdentifier(kind: .audiobook, connectionID: "c", libraryID: "l1", primaryID: "p")
        let b = ItemIdentifier(kind: .series, connectionID: "c", libraryID: "", primaryID: "p")
        #expect(a.storageKey == b.storageKey)
        let episode = ItemIdentifier(kind: .episode, connectionID: "c", libraryID: "l", primaryID: "e", groupingID: "pod")
        #expect(episode.storageKey == "c::e::pod")
    }

    @Test func deviceInfoIsPersistent() throws {
        let defaults = try #require(UserDefaults(suiteName: "dev.hearth.tests.\(UUID().uuidString)"))
        let first = DeviceInfoProvider.make(defaults: defaults)
        let second = DeviceInfoProvider.make(defaults: defaults)
        #expect(first.deviceID == second.deviceID)
        #expect(!first.model.isEmpty)
        #expect(first.clientName == "Hearth")
    }

    @Test func credentialTokenStoreCachesAndPersists() async {
        let credentials = InMemoryCredentialStore()
        let store = CredentialTokenStore(credentials: credentials)
        await store.store(AuthTokens(accessToken: "a", refreshToken: nil), for: "c")
        #expect(credentials.tokens(for: "c")?.accessToken == "a")
        #expect(await store.tokens(for: "c")?.isLegacy == true)
        store.remove("c")
        #expect(await store.tokens(for: "c") == nil)
    }

    @MainActor
    @Test func itemSettingsRoundTrip() async {
        let hearth = makeHearth([MockClient(connection: Fixtures.connection())])
        let book = Fixtures.bookID("b", connection: "conn")
        hearth.itemSettings.setPlaybackRate(1.5, for: book)
        hearth.itemSettings.setSleepTimer(.chapters(2), for: book)
        hearth.itemSettings.setAllowsSuggestions(false, for: book)
        #expect(hearth.itemSettings.playbackRate(for: book) == 1.5)
        #expect(hearth.itemSettings.sleepTimer(for: book) == .chapters(2))
        #expect(!hearth.itemSettings.allowsSuggestions(for: book))

        await hearth.itemSettings.flush()
        let reloaded = ItemSettingsStore(environment: hearth.environment)
        #expect(reloaded.playbackRate(for: book) == 1.5)

        hearth.itemSettings.setDisplayMode(.list, for: "library")
        #expect(hearth.itemSettings.displayMode(for: "library") == .list)
        hearth.itemSettings.setLibrarySort(AudiobookSortOrder.title, direction: .descending, for: "library")
        let (sort, direction) = hearth.itemSettings.librarySort(for: "library", default: AudiobookSortOrder.added)
        #expect(sort == .title && direction == .descending)
        let library = LibraryIdentifier(connectionID: "conn", libraryID: "books")
        #expect(hearth.itemSettings.tabs(for: library) == nil)
        hearth.itemSettings.setTabs([.home, .series], for: library)
        #expect(hearth.itemSettings.tabs(for: library) == [.home, .series])
    }
}

@Suite("Connections & listening")
@MainActor
struct ConnectionAndListeningTests {
    @Test func allConnectionsFailingEntersOfflineMode() async {
        let client = MockClient(connection: Fixtures.connection())
        client.update { $0.failAll = true }
        let hearth = makeHearth([client])
        await hearth.connections.reloadLibraries()
        #expect(hearth.connections.isOffline)
        #expect(hearth.connections.offlineReason == .unreachable)

        client.update {
            $0.failAll = false
            $0.libraries = [Library(id: LibraryIdentifier(connectionID: client.connection.id, libraryID: "l"), name: "L", mediaType: .audiobooks, displayOrder: 0)]
        }
        await hearth.connections.retryOffline()
        #expect(!hearth.connections.isOffline)
        #expect(hearth.connections.allLibraries.count == 1)
        #expect(hearth.connections.status[client.connection.id] == .online)
    }

    @Test func userOfflineModeIsSticky() async {
        let client = MockClient(connection: Fixtures.connection())
        let hearth = makeHearth([client])
        await hearth.connections.setOffline(true)
        await hearth.connections.reloadLibraries()
        #expect(hearth.connections.isOffline)
        #expect(hearth.connections.offlineReason == .user)
        await hearth.connections.setOffline(false)
        #expect(!hearth.connections.isOffline)
    }

    @Test func removingConnectionPurgesData() async throws {
        let client = MockClient(connection: Fixtures.connection())
        let book = Fixtures.bookID("b", connection: client.connection.id)
        let hearth = makeHearth([client])
        await hearth.progress.update(book, currentTime: 5, duration: 10)
        try await hearth.bookmarks.create(book, time: 1, note: "x")

        await hearth.connections.remove(client.connection.id)
        #expect(hearth.connections.connections.isEmpty)
        #expect(hearth.progress.progress(for: book) == nil)
        #expect(hearth.bookmarks.bookmarks(for: book).isEmpty)
        #expect(ProgressStore(environment: hearth.environment).record(for: book) == nil)
    }

    @Test func legacyAuthenticationDetection() async {
        let client = MockClient(connection: Fixtures.connection())
        let hearth = makeHearth([client])
        #expect(!(await hearth.connections.isUsingLegacyAuthentication(client.connection.id)))
        await hearth.connections.updateTokens(AuthTokens(accessToken: "legacy", refreshToken: nil), for: client.connection.id)
        #expect(await hearth.connections.isUsingLegacyAuthentication(client.connection.id))
    }

    @Test func listenedTodayCombinesServerLocalAndUnreported() async {
        let client = MockClient(connection: Fixtures.connection())
        let book = Fixtures.bookID("b", connection: client.connection.id)
        client.update {
            $0.sessions = [
                ListeningSession(id: "s1", itemID: book, displayTitle: nil, timeListening: 600, startTime: 0, currentTime: 600, startedAt: .now, updatedAt: .now, deviceName: nil),
                ListeningSession(id: "s0", itemID: book, displayTitle: nil, timeListening: 900, startTime: 0, currentTime: 900, startedAt: .now.addingTimeInterval(-3 * 86_400), updatedAt: .now.addingTimeInterval(-3 * 86_400), deviceName: nil),
            ]
        }
        let hearth = makeHearth([client])
        await hearth.listening.refresh()
        #expect(hearth.listening.listenedToday == 600)

        // Reported to the server session after the fetch.
        hearth.listening.addUnreported(30)
        #expect(hearth.listening.listenedToday == 630)

        // Recorded locally (server unreachable): counted on its own.
        await hearth.listening.recordLocalSession(itemID: book, startTime: 0, currentTime: 20, duration: 100, timeListened: 20)
        #expect(hearth.listening.listenedToday == 650)

        // Uploading moves it to the server bucket without changing the total.
        await hearth.listening.closeLocalSession(itemID: book)
        #expect(client.read { $0.uploadedSessions.map(\.timeListened) } == [20])
        #expect(hearth.listening.listenedToday == 650)

        // A refresh replaces the estimate with the server's numbers.
        await hearth.listening.refresh()
        #expect(hearth.listening.listenedToday == 600)
    }

    @Test func offlineModeDisconnectsSockets() async throws {
        let client = MockClient(connection: Fixtures.connection())
        let hearth = makeHearth([client])
        hearth.startLiveUpdates()
        // Toggled within one main actor turn: `APINetworkPolicy.shared` is process wide.
        hearth.connections.isOffline = true
        hearth.connections.isOffline = false
        for _ in 0 ..< 200 where client.read({ $0.socketDisconnects }) == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(client.read { $0.socketDisconnects } == 1)
        hearth.stopLiveUpdates()
    }

    @Test func staleServerSessionsAreClosed() async {
        let client = MockClient(connection: Fixtures.connection())
        let book = Fixtures.bookID("b", connection: client.connection.id)
        let first = makeHearth([client])
        first.listening.registerOpenSession("old", itemID: book)

        // Simulate the next launch with the same defaults.
        let next = ListeningTracker(environment: first.environment)
        next.hearth = first
        await next.closeStaleSessions()
        #expect(client.read { $0.closedSessionsWithoutProgress } == ["old"])
    }
}
