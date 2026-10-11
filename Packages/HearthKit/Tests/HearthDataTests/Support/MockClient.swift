import Foundation
import HearthAPI
import HearthModel
import Synchronization

/// Scriptable in-memory `AudiobookshelfClient`.
final class MockClient: AudiobookshelfClient {
    struct State {
        var failAll = false
        var failProgressDeletes = false
        var failBookmarkWrites = false

        var libraries: [Library] = []
        var authorizeProgress: [ProgressEntity] = []
        var authorizeBookmarks: [Bookmark] = []
        var authorizeUnresolved: Set<String> = []
        /// Delays `authorize()` (to change local state while the request is in flight).
        var authorizeDelay: Duration?
        var authorizeCount = 0
        var audiobooks: [String: Audiobook] = [:]
        var seriesBooks: [String: [Audiobook]] = [:]
        var podcasts: [String: (Podcast, [Episode])] = [:]
        var collections: [String: ItemCollection] = [:]
        var searchResults: [String: SearchResults] = [:]
        var sessions: [ListeningSession] = []

        var pushedProgress: [[ProgressEntity]] = []
        var deletedProgress: [String] = []
        var hiddenProgress: [String] = []
        var createdBookmarks: [Bookmark] = []
        var updatedBookmarks: [Bookmark] = []
        var deletedBookmarks: [Bookmark] = []
        var uploadedSessions: [LocalSessionUpload] = []
        var closedSessions: [String] = []
        var closedSessionsWithoutProgress: [String] = []
        var authorizationRefreshes = 0
        var uploadDelay: Duration?
        var uploadCount = 0
        /// Order of `authorize` / `close` calls.
        var calls: [String] = []
        var searchedLibraries: [LibraryIdentifier] = []
    }

    let connection: Connection
    let state = Mutex(State())

    init(connection: Connection) {
        self.connection = connection
    }

    func update(_ body: (inout State) -> Void) {
        state.withLock { body(&$0) }
    }

    func read<T>(_ body: (State) -> T) -> T {
        state.withLock { body($0) }
    }

    /// Waits until `authorize()` was called (the request is in flight while `authorizeDelay` is set).
    func waitForAuthorize() async {
        while read({ $0.authorizeCount }) == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func check() throws {
        if state.withLock({ $0.failAll }) {
            throw APIError.unreachable
        }
    }

    // MARK: Account

    func me() async throws -> (userID: String, username: String) {
        try check()
        return ("user", connection.username)
    }

    func authorize() async throws -> AuthorizeResponse {
        try check()
        // The server state is captured when the request is handled, before the (delayed) response arrives.
        let response = state.withLock {
            $0.authorizeCount += 1
            $0.calls.append("authorize")
            return AuthorizeResponse(userID: "user", username: connection.username, progress: $0.authorizeProgress, bookmarks: $0.authorizeBookmarks, unresolvedItemIDs: $0.authorizeUnresolved)
        }
        if let delay = state.withLock({ $0.authorizeDelay }) {
            try await Task.sleep(for: delay)
        }
        return response
    }

    // MARK: Libraries

    func libraries() async throws -> [Library] {
        try check()
        return state.withLock { $0.libraries }
    }

    func filterData(library: LibraryIdentifier) async throws -> LibraryFilterData { LibraryFilterData() }
    func home(library: Library) async throws -> [HomeRow] { [] }
    func recentEpisodes(library: LibraryIdentifier, limit: Int) async throws -> [Episode] { [] }

    // MARK: Lists

    func audiobooks(library: LibraryIdentifier, sort: AudiobookSortOrder?, direction: SortDirection, filter: LibraryItemFilter?, collapseSeries: Bool, page: Int, limit: Int) async throws -> Page<LibraryEntry> {
        try check()
        guard case .series(let id)? = filter else { return Page(items: [], total: 0, page: page) }
        let books = state.withLock { $0.seriesBooks[id] ?? [] }
        let slice = books.dropFirst(page * limit).prefix(limit)
        return Page(items: slice.map(LibraryEntry.audiobook), total: books.count, page: page)
    }

    func podcasts(library: LibraryIdentifier, sort: PodcastSortOrder, direction: SortDirection, page: Int, limit: Int) async throws -> Page<Podcast> { Page(items: [], total: 0, page: page) }
    func series(library: LibraryIdentifier, sort: SeriesSortOrder, direction: SortDirection, filter: LibraryItemFilter?, page: Int, limit: Int) async throws -> Page<Series> { Page(items: [], total: 0, page: page) }
    func authors(library: LibraryIdentifier, sort: AuthorSortOrder, direction: SortDirection, page: Int, limit: Int) async throws -> Page<Person> { Page(items: [], total: 0, page: page) }
    func narrators(library: LibraryIdentifier) async throws -> [Person] { [] }
    func collections(library: LibraryIdentifier, page: Int, limit: Int) async throws -> Page<ItemCollection> { Page(items: [], total: 0, page: page) }
    func playlists(library: LibraryIdentifier, page: Int, limit: Int) async throws -> Page<ItemCollection> { Page(items: [], total: 0, page: page) }

    func search(library: LibraryIdentifier, query: String, limit: Int) async throws -> SearchResults {
        try check()
        return state.withLock {
            $0.searchedLibraries.append(library)
            return $0.searchResults[library.libraryID] ?? SearchResults()
        }
    }

    // MARK: Single items

    func audiobook(_ id: ItemIdentifier) async throws -> Audiobook {
        try check()
        guard let book = state.withLock({ $0.audiobooks[id.primaryID] }) else { throw APIError.notFound }
        return book
    }

    func podcast(_ id: ItemIdentifier) async throws -> (podcast: Podcast, episodes: [Episode]) {
        try check()
        guard let entry = state.withLock({ $0.podcasts[id.primaryID] }) else { throw APIError.notFound }
        return entry
    }

    func episode(_ id: ItemIdentifier) async throws -> Episode {
        try check()
        guard let podcastID = id.groupingID, let episode = state.withLock({ $0.podcasts[podcastID]?.1.first { $0.id.primaryID == id.primaryID } }) else {
            throw APIError.notFound
        }
        return episode
    }

    func playableDetails(_ id: ItemIdentifier) async throws -> PlayableItemDetails {
        try check()
        let book = try await audiobook(id)
        return PlayableItemDetails(item: .audiobook(book), audioFiles: [AudioFile(ino: "1", fileExtension: ".m4b", offset: 0, duration: book.duration)], chapters: [], pdfs: [], progress: nil)
    }

    func author(_ id: ItemIdentifier) async throws -> (author: Person, audiobooks: [Audiobook], series: [Series]) { throw APIError.notFound }
    func narrator(_ id: ItemIdentifier) async throws -> (narrator: Person, audiobooks: [Audiobook]) { throw APIError.notFound }

    func seriesDetails(_ id: ItemIdentifier) async throws -> Series {
        try check()
        let books = state.withLock { $0.seriesBooks[id.primaryID] ?? [] }
        return Series(id: id, name: "Series", audiobooks: books)
    }

    func collection(_ id: ItemIdentifier) async throws -> ItemCollection {
        try check()
        guard let collection = state.withLock({ $0.collections[id.primaryID] }) else { throw APIError.notFound }
        return collection
    }

    func updateEpisodeType(_ id: ItemIdentifier, type: Episode.EpisodeType) async throws {}

    // MARK: Collections

    func createCollection(name: String, library: LibraryIdentifier, items: [ItemIdentifier], playlist: Bool) async throws -> ItemIdentifier { throw APIError.notFound }
    func updateCollection(_ id: ItemIdentifier, name: String?, description: String?, items: [ItemIdentifier]?) async throws {}
    func addToCollection(_ id: ItemIdentifier, items: [ItemIdentifier]) async throws {}
    func removeFromCollection(_ id: ItemIdentifier, items: [ItemIdentifier]) async throws {}
    func deleteCollection(_ id: ItemIdentifier) async throws {}
    func createPlaylist(fromCollection id: ItemIdentifier) async throws -> ItemIdentifier { throw APIError.notFound }

    // MARK: Sessions

    func startSession(_ id: ItemIdentifier, device: DeviceInfo) async throws -> PlaybackSessionInfo { throw APIError.notFound }
    func syncSession(_ sessionID: String, currentTime: TimeInterval, duration: TimeInterval, timeListened: TimeInterval) async throws {}

    func closeSession(_ sessionID: String, currentTime: TimeInterval, duration: TimeInterval, timeListened: TimeInterval) async throws {
        try check()
        state.withLock { $0.closedSessions.append(sessionID) }
    }

    func closeSession(_ sessionID: String) async throws {
        try check()
        state.withLock {
            $0.closedSessionsWithoutProgress.append(sessionID)
            $0.calls.append("close \(sessionID)")
        }
    }

    func uploadLocalSession(_ session: LocalSessionUpload, device: DeviceInfo) async throws {
        try check()
        let delay = state.withLock {
            $0.uploadCount += 1
            return $0.uploadDelay
        }
        if let delay {
            try await Task.sleep(for: delay)
        }
        state.withLock { $0.uploadedSessions.append(session) }
    }

    func listeningSessions(page: Int, perPage: Int) async throws -> Page<ListeningSession> {
        try check()
        let sessions = state.withLock { $0.sessions }
        return Page(items: Array(sessions.dropFirst(page * perPage).prefix(perPage)), total: sessions.count, page: page)
    }

    func listeningSessions(for id: ItemIdentifier, page: Int, perPage: Int) async throws -> Page<ListeningSession> {
        try await listeningSessions(page: page, perPage: perPage)
    }

    func listeningStats() async throws -> ListeningStats {
        ListeningStats(days: [:], totalTime: 0, today: 0, topItems: [])
    }

    // MARK: Progress

    func batchUpdateProgress(_ entries: [ProgressEntity]) async throws {
        try check()
        state.withLock { $0.pushedProgress.append(entries) }
    }

    func deleteProgress(id: String) async throws {
        try check()
        if state.withLock({ $0.failProgressDeletes }) {
            throw APIError.transport("delete failed")
        }
        state.withLock { $0.deletedProgress.append(id) }
    }

    func setFinished(_ id: ItemIdentifier, finished: Bool) async throws {}

    func hideFromContinueListening(progressID: String) async throws {
        try check()
        state.withLock { $0.hiddenProgress.append(progressID) }
    }

    // MARK: Bookmarks

    private func checkBookmarks() throws {
        try check()
        if state.withLock({ $0.failBookmarkWrites }) {
            throw APIError.transport("bookmark write failed")
        }
    }

    func createBookmark(_ id: ItemIdentifier, time: Int, note: String) async throws -> Bookmark {
        try checkBookmarks()
        let bookmark = Bookmark(itemID: id, time: time, note: note, created: Date(timeIntervalSince1970: 1_000))
        state.withLock { $0.createdBookmarks.append(bookmark) }
        return bookmark
    }

    func updateBookmark(_ id: ItemIdentifier, time: Int, note: String) async throws {
        try checkBookmarks()
        state.withLock { $0.updatedBookmarks.append(Bookmark(itemID: id, time: time, note: note, created: .now)) }
    }

    func deleteBookmark(_ id: ItemIdentifier, time: Int) async throws {
        try checkBookmarks()
        state.withLock { $0.deletedBookmarks.append(Bookmark(itemID: id, time: time, note: "", created: .now)) }
    }

    // MARK: Files

    func coverRequest(for id: ItemIdentifier, size: ImageSize) async throws -> URLRequest {
        URLRequest(url: connection.host.appending(path: "api/items/\(id.apiItemID)/cover"))
    }

    func audioFileRequest(for id: ItemIdentifier, ino: String) async throws -> URLRequest {
        URLRequest(url: connection.host.appending(path: "api/items/\(id.apiItemID)/file/\(ino)/download"))
    }

    func pdfRequest(for id: ItemIdentifier, ino: String) async throws -> URLRequest {
        URLRequest(url: connection.host.appending(path: "api/items/\(id.apiItemID)/ebook/\(ino)"))
    }

    func streamingHeaders() async throws -> [String: String] { [:] }

    func refreshAuthorization(rejectedRequest: URLRequest) async throws {
        try check()
        state.withLock { $0.authorizationRefreshes += 1 }
    }
    func webURL(for id: ItemIdentifier) -> URL { connection.host }

    // MARK: Live updates

    func events() -> AsyncStream<ServerEvent> { AsyncStream { $0.finish() } }
    func connectSocket() async {}
    func disconnectSocket() async {}
}
