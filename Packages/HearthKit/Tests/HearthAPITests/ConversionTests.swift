import Foundation
import HearthModel
import Testing
@testable import HearthAPI

@Suite struct ConversionTests {
    let converter = PayloadConverter(connectionID: "conn", host: URL(string: "https://example.com/abs")!)

    @Test func librariesSkipUnknownMediaTypes() throws {
        let payload = try Fixture.decode(LibrariesResponsePayload.self, "libraries")
        let libraries = payload.libraries.compactMap(converter.library)
        #expect(libraries.map(\.name) == ["Podcasts", "Audiobooks"])
        #expect(libraries.first?.mediaType == .podcasts)
        #expect(libraries.last?.id == LibraryIdentifier(connectionID: "conn", libraryID: "lib_books"))
    }

    @Test func expandedBookConvertsToAudiobookAndDetails() throws {
        let item = try Fixture.decode(LibraryItemPayload.self, "item-book-expanded")
        let audiobook = try #require(converter.audiobook(item))

        #expect(audiobook.id.description == "audiobook::conn::lib_books::li_book1")
        #expect(audiobook.name == "Wizards First Rule")
        #expect(audiobook.authors == ["Terry Goodkind"])
        #expect(audiobook.narrators == ["Sam Tsoutsouvas"])
        #expect(audiobook.series == [SeriesFragment(id: "ser_sot", name: "Sword of Truth", sequence: "1")])
        #expect(audiobook.released == "2008")
        #expect(audiobook.asin == "B002V0QK4C")
        #expect(audiobook.tags == ["Favorite"])
        #expect(audiobook.duration == 11922.9075)
        #expect(audiobook.size == 97626112)
        #expect(audiobook.hasAudio)
        #expect(audiobook.pdfs == [PDFFile(ino: "649644248522215300", name: "Map of the Midlands")])
        #expect(audiobook.addedAt == Date(timeIntervalSince1970: 1650621073.750))

        let details = try #require(converter.playableDetails(item, episodeID: nil, library: nil))
        #expect(details.audioFiles == [
            AudioFile(ino: "649644248522215261", fileExtension: "mp3", offset: 0, duration: 6004.6675, mimeType: "audio/mpeg"),
            AudioFile(ino: "649644248522215262", fileExtension: "mp3", offset: 6004.6675, duration: 5918.24, mimeType: "audio/mpeg"),
        ])
        #expect(details.chapters.count == 2)
        #expect(details.chapters[1] == Chapter(id: 1, start: 6004.6675, end: 11922.9075, title: "Wizards First Rule 02"))
        #expect(details.pdfs.count == 1)
        let progress = try #require(details.progress)
        #expect(progress.id == "mp_book1")
        #expect(progress.itemID == audiobook.id)
        #expect(progress.progress == 0.25)
        #expect(progress.currentTime == 2980.72)
        #expect(progress.lastUpdate == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(progress.finishedAt == nil)
    }

    @Test func audioFilesFallBackToIncludedFilesWithOffsets() throws {
        var item = try Fixture.decode(LibraryItemPayload.self, "item-book-expanded")
        item.media?.tracks = []
        let files = converter.audioFiles(of: try #require(item.media))
        #expect(files.map(\.ino) == ["649644248522215261", "649644248522215262"])
        #expect(files.map(\.offset) == [0, 6004.6675])
    }

    @Test func collapsedSeriesAndLenientListEntries() throws {
        let payload = try Fixture.decode(PagedPayload<LibraryItemPayload>.self, "items-collapsed")
        #expect(payload.total == 42)
        let entries = payload.results.compactMap { converter.libraryEntry($0, library: "lib_books") }
        #expect(entries.count == 3)

        guard case .audiobook(let book) = entries[0] else {
            Issue.record("Expected audiobook")
            return
        }
        #expect(book.duration == 164532.5)
        #expect(book.narrators == ["Michael Kramer", "Kate Reading"])
        #expect(book.series == [
            SeriesFragment(id: nil, name: "The Stormlight Archive", sequence: "1"),
            SeriesFragment(id: nil, name: "Cosmere", sequence: "3.5"),
        ])

        guard case .collapsedSeries(let series) = entries[1] else {
            Issue.record("Expected collapsed series")
            return
        }
        #expect(series.id.description == "series::conn::lib_books::ser_expanse")
        #expect(series.name == "The Expanse")
        #expect(series.bookCount == 9)
        #expect(series.audiobooks.first?.name == "Leviathan Wakes")

        guard case .audiobook(let ebook) = entries[2] else {
            Issue.record("Expected audiobook")
            return
        }
        #expect(!ebook.hasAudio)
    }

    @Test func podcastWithEpisodesAndParsedChapters() throws {
        let item = try Fixture.decode(LibraryItemPayload.self, "item-podcast-expanded")
        let podcast = try #require(converter.podcast(item))
        #expect(podcast.id.description == "podcast::conn::lib_pods::li_pod1")
        #expect(podcast.name == "Dan Carlin's Hardcore History")
        #expect(podcast.authors == ["Dan Carlin"])
        #expect(podcast.explicit)
        #expect(podcast.publishingType == .serial)
        #expect(podcast.episodeCount == 2)
        #expect(podcast.feedURL == URL(string: "https://feeds.example.com/hardcorehistory"))
        #expect(converter.audiobook(item) == nil)

        let episodes = converter.episodes(of: item)
        #expect(episodes.count == 2)
        let first = episodes[0]
        #expect(first.id.description == "episode::conn::lib_pods::ep_1::li_pod1")
        #expect(first.id.apiItemID == "li_pod1")
        #expect(first.id.apiEpisodeID == "ep_1")
        #expect(first.podcastName == "Dan Carlin's Hardcore History")
        #expect(first.season == "1")
        #expect(first.episode == "68")
        #expect(first.type == .full)
        #expect(first.publishedAt == Date(timeIntervalSince1970: 1_383_080_400))
        #expect(first.duration == 11220.5)
        #expect(first.size == 150000000)
        #expect(episodes[1].type == .trailer)
        #expect(episodes[1].duration == 120)

        let details = try #require(converter.playableDetails(item, episodeID: "ep_1", library: nil))
        #expect(details.audioFiles == [AudioFile(ino: "101", fileExtension: "mp3", offset: 0, duration: 11220.5, mimeType: "audio/mpeg")])
        #expect(details.chapters.map(\.title) == ["Intro", "The Assassination", "Mobilization & War"])
        #expect(details.chapters.last?.end == 11220.5)

        let trailer = try #require(converter.playableDetails(item, episodeID: "ep_2", library: nil))
        #expect(trailer.audioFiles.first?.fileExtension == "m4a")
        #expect(trailer.chapters.map(\.title) == ["Part A", "Part B"])
        #expect(converter.playableDetails(item, episodeID: "missing", library: nil) == nil)
    }

    @Test func podcastListReadsIncompleteCount() throws {
        let payload = try Fixture.decode(PagedPayload<LibraryItemPayload>.self, "podcasts")
        let podcasts = payload.results.compactMap { converter.podcast($0, library: "lib_pods") }
        #expect(podcasts.map(\.episodeCount) == [12, 3])
        #expect(podcasts.map(\.incompleteEpisodeCount) == [5, nil])
        #expect(podcasts[0].publishingType == .episodic)
        #expect(podcasts[1].authors.isEmpty)
    }

    @Test func personalizedBookShelves() throws {
        let shelves = try Fixture.decode([Failable<ShelfPayload>].self, "personalized-books").compactMap(\.value)
        let rows = converter.homeRows(shelves, library: "lib_books")
        #expect(rows.map(\.id) == ["continue-listening", "continue-series", "recent-series", "newest-authors"])

        guard case .audiobook(let continueSeries) = rows[1].items.first else {
            Issue.record("Expected audiobook")
            return
        }
        // `metadata.series` is a single object in the continue-series shelf.
        #expect(continueSeries.series == [SeriesFragment(id: "ser_sot", name: "Sword of Truth", sequence: "2")])

        guard case .series(let series) = rows[2].items.first else {
            Issue.record("Expected series")
            return
        }
        #expect(series.audiobooks.map(\.name) == ["Leviathan Wakes", "Caliban's War"])
        #expect(series.bookCount == 2)
        #expect(series.authors == ["James S. A. Corey"])

        let authors = rows[3].items.compactMap { item -> Person? in
            if case .person(let person) = item { person } else { nil }
        }
        #expect(authors.map(\.id.kind) == [.author, .author])
        #expect(authors.map(\.hasImage) == [true, false])
        #expect(authors.map(\.bookCount) == [2, 9])
    }

    @Test func personalizedPodcastShelves() throws {
        let shelves = try Fixture.decode([Failable<ShelfPayload>].self, "personalized-podcasts").compactMap(\.value)
        let rows = converter.homeRows(shelves, library: "lib_pods")
        #expect(rows.count == 2)
        guard case .episode(let episode) = rows[0].items.first else {
            Issue.record("Expected episode")
            return
        }
        #expect(episode.id == ItemIdentifier(kind: .episode, connectionID: "conn", libraryID: "lib_pods", primaryID: "ep_1", groupingID: "li_pod1"))
        #expect(episode.podcastName == "Dan Carlin's Hardcore History")
        #expect(episode.season == nil)
        #expect(episode.duration == 11220.5)
        guard case .podcast(let podcast) = rows[1].items.first else {
            Issue.record("Expected podcast")
            return
        }
        #expect(podcast.name == "Second Podcast")
    }

    @Test func recentEpisodesUseNestedPodcast() throws {
        let payload = try Fixture.decode(RecentEpisodesPayload.self, "recent-episodes")
        let episodes = payload.episodes.compactMap { converter.episode($0, library: "fallback") }
        #expect(episodes.count == 1)
        #expect(episodes[0].podcastName == "Dan Carlin's Hardcore History")
        #expect(episodes[0].id.libraryID == "lib_pods")
        #expect(episodes[0].authors == ["Dan Carlin"])
    }

    @Test func playbackSessionResolvesTrackURLsAndParsesEpisodeChapters() throws {
        let payload = try Fixture.decode(PlaybackSessionPayload.self, "session-play")
        let session = converter.playbackSession(payload)
        #expect(session.id == "play_session_1")
        #expect(session.startTime == 120.5)
        #expect(session.duration == 11220.5)
        #expect(session.tracks == [AudioTrack(index: 1, offset: 0, duration: 11220.5, url: URL(string: "https://example.com/abs/api/items/li_pod1/file/101")!, mimeType: "audio/mpeg")])
        #expect(session.chapters.map(\.start) == [0, 750, 3910])
    }

    @Test func authorizeMapsProgressAndBookmarksViaDirectory() throws {
        let user = try Fixture.decode(UserResponsePayload.self, "authorize").user
        #expect(user.bestAccessToken == "legacy-token")

        // Unknown items cannot be mapped until their library is known.
        #expect(user.mediaProgress.compactMap(converter.progress).isEmpty)

        let batch = try Fixture.decode(BatchItemsPayload.self, "batch-get")
        for item in batch.libraryItems {
            converter.register(item, library: nil)
        }

        let progress = user.mediaProgress.compactMap(converter.progress)
        #expect(progress.map(\.id) == ["mp_book1", "mp_ep1"])
        #expect(progress[0].itemID == ItemIdentifier(kind: .audiobook, connectionID: "conn", libraryID: "lib_books", primaryID: "li_book1"))
        #expect(progress[0].isInProgress)
        #expect(progress[1].itemID == ItemIdentifier(kind: .episode, connectionID: "conn", libraryID: "lib_pods", primaryID: "ep_1", groupingID: "li_pod1"))
        #expect(progress[1].itemID.kind == .episode)
        #expect(progress[1].isFinished)
        #expect(progress[1].progress == 1)
        #expect(progress[1].hideFromContinueListening)
        #expect(progress[1].finishedAt == Date(timeIntervalSince1970: 1_700_000_100))

        let bookmarks = user.bookmarks.compactMap(converter.bookmark)
        #expect(bookmarks == [Bookmark(itemID: progress[0].itemID, time: 1234, note: "Great quote", created: Date(timeIntervalSince1970: 1_700_000_200))])
    }

    @Test func unfinishedProgressNeverReportsFinished() {
        let json = #"{"id":"p","libraryItemId":"li","progress":1,"currentTime":10,"isFinished":false}"#
        let payload = try! JSONDecoder().decode(MediaProgressPayload.self, from: Data(json.utf8))
        let entity = converter.progress(payload, itemID: ItemIdentifier(kind: .audiobook, connectionID: "c", libraryID: "l", primaryID: "li"))
        #expect(!entity.isFinished)
        #expect(entity.lastUpdate == .distantPast)
    }

    @Test func listeningSessionsAndStats() throws {
        let payload = try Fixture.decode(ListeningSessionsPayload.self, "listening-sessions")
        let sessions = payload.sessions.map(converter.listeningSession)
        #expect(payload.total == 23)
        #expect(sessions[0].itemID?.description == "audiobook::conn::lib_books::li_book1")
        #expect(sessions[0].displayTitle == "Wizards First Rule")
        #expect(sessions[0].timeListening == 600)
        #expect(sessions[0].deviceName == "Hearth – iPhone17,1")
        #expect(sessions[1].itemID?.description == "episode::conn::lib_pods::ep_1::li_pod1")
        #expect(sessions[1].displayTitle == "Dan Carlin's Hardcore History")
        #expect(sessions[1].timeListening == 120)
        #expect(sessions[1].deviceName == "Robin's iPad")

        let stats = converter.listeningStats(try Fixture.decode(ListeningStatsPayload.self, "listening-stats"))
        #expect(stats.totalTime == 5400.5)
        #expect(stats.today == 1800.5)
        #expect(stats.days == ["2024-05-01": 3600, "2024-05-02": 1800.5])
        #expect(stats.topItems.map(\.id) == ["li_book1", "li_pod1"])
        #expect(stats.topItems.map(\.title) == ["Wizards First Rule", "Dan Carlin's Hardcore History"])
    }

    @Test func searchResults() throws {
        let payload = try Fixture.decode(SearchResponsePayload.self, "search")
        let results = converter.searchResults(payload, library: "lib_books")
        #expect(results.audiobooks.map(\.name) == ["Wizards First Rule"])
        #expect(results.audiobooks.first?.hasAudio == true)
        #expect(results.narrators.map(\.name) == ["Sam Tsoutsouvas"])
        #expect(results.narrators.first?.id.kind == .narrator)
        #expect(results.series.first?.audiobooks.count == 1)
        #expect(results.authors.first?.bookCount == 2)
        #expect(results.episodes.first?.id.description == "episode::conn::lib_pods::ep_1::li_pod1")
        #expect(results.podcasts.isEmpty)
    }

    @Test func playlistWithBooksAndEpisodes() throws {
        let payload = try Fixture.decode(CollectionPayload.self, "playlist")
        let playlist = converter.collection(payload, isPlaylist: true)
        #expect(playlist.id.description == "playlist::conn::lib_books::pl_1")
        #expect(playlist.isPlaylist)
        #expect(playlist.descriptionHTML == "Things for the train")
        #expect(playlist.items.count == 2)
        guard case .episode(let episode) = playlist.items[1] else {
            Issue.record("Expected episode")
            return
        }
        // Episodes keep their podcast's library even inside a playlist of another library.
        #expect(episode.id.libraryID == "lib_pods")
        #expect(episode.type == .bonus)
        #expect(episode.podcastName == "Dan Carlin's Hardcore History")
    }

    @Test func authorWithSeriesGroups() throws {
        let payload = try Fixture.decode(AuthorPayload.self, "author")
        let author = converter.author(payload)
        #expect(author.id.description == "author::conn::lib_books::aut_goodkind")
        #expect(author.hasImage)
        #expect(author.bookCount == 2)
        #expect(payload.series.first?.items.count == 2)
    }

    @Test func seriesListPayload() throws {
        let payload = try Fixture.decode(PagedPayload<SeriesPayload>.self, "series")
        let series = try #require(payload.results.first.map { converter.series($0) })
        #expect(payload.total == 17)
        #expect(series.totalDuration == 150000)
        #expect(series.audiobooks.map(\.series.first?.sequence) == ["1", "2"])
    }

    @Test func narratorIdentifierRoundTrip() {
        let person = converter.narrator(name: "Kate Reading", bookCount: 3, library: "lib")
        #expect(person.id.primaryID == "S2F0ZSBSZWFkaW5n")
        #expect(PayloadConverter.narratorName(primaryID: person.id.primaryID) == "Kate Reading")
        // Server ids are URL encoded base64.
        #expect(PayloadConverter.narratorName(primaryID: "S2F0ZSBSZWFkaW5n%3D") == "Kate Reading")
        #expect(ItemIdentifier(person.id.description) == person.id)
    }

    @Test func statusAndLoginPayloads() throws {
        let status = try Fixture.decode(StatusPayload.self, "status")
        #expect(status.isInit)
        #expect(status.authMethods.compactMap(AuthMethod.init(rawValue:)) == [.local, .openID])
        #expect(status.openIDButtonText == "Login with Authentik")

        let login = try AuthenticatorImplementation.loginResult(from: Fixture.data("login"))
        #expect(login.tokens == AuthTokens(accessToken: "access-1", refreshToken: "refresh-1"))
        #expect(login.userID == "usr_1")
        #expect(login.username == "robin")
    }

    @Test func localSessionBody() throws {
        let itemID = ItemIdentifier(kind: .episode, connectionID: "c", libraryID: "lib_pods", primaryID: "ep_1", groupingID: "li_pod1")
        let started = Date(timeIntervalSince1970: 1_714_550_400) // Wed 2024-05-01 08:00 UTC
        let upload = LocalSessionUpload(id: "local-1", itemID: itemID, startTime: 10, currentTime: 70, duration: 100, timeListened: 60, startedAt: started, updatedAt: started.addingTimeInterval(60))
        let device = DeviceInfo(deviceID: "dev", clientVersion: "1.0", model: "iPhone17,1", osName: "iOS", osVersion: "26.0")
        let body = LocalSessionBody(upload, userID: "usr_1", device: device, timeZone: TimeZone(identifier: "UTC")!)
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder.api.encode(body)) as? [String: Any])

        #expect(json["id"] as? String == "local-1")
        #expect(json["libraryItemId"] as? String == "li_pod1")
        #expect(json["episodeId"] as? String == "ep_1")
        #expect(json["libraryId"] as? String == "lib_pods")
        #expect(json["mediaType"] as? String == "podcast")
        #expect(json["playMethod"] as? Int == 3)
        #expect(json["date"] as? String == "2024-05-01")
        #expect(json["dayOfWeek"] as? String == "Wednesday")
        #expect(json["timeListening"] as? Double == 60)
        #expect(json["startedAt"] as? Int64 == 1_714_550_400_000)
        #expect(json["updatedAt"] as? Int64 == 1_714_550_460_000)
        #expect((json["deviceInfo"] as? [String: Any])?["osName"] as? String == "iOS")
        #expect((json["deviceInfo"] as? [String: Any])?["clientName"] as? String == "Hearth")
    }

    @Test func progressBatchBodyOmitsNilValues() throws {
        let entity = ProgressEntity(id: "p", itemID: ItemIdentifier(kind: .audiobook, connectionID: "c", libraryID: "l", primaryID: "li"), progress: 0.5, duration: nil, currentTime: 30, startedAt: nil, lastUpdate: Date(timeIntervalSince1970: 1), finishedAt: nil)
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder.api.encode(ProgressUpdateBody(entity))) as? [String: Any])
        #expect(Set(json.keys) == ["libraryItemId", "progress", "currentTime", "isFinished", "hideFromContinueListening", "lastUpdate"])
        #expect(json["lastUpdate"] as? Int == 1000)
    }
}
