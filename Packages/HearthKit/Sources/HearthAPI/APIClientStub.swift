// TEMPORARY STUB – replaced by the real implementation.
import Foundation
import HearthModel

enum AuthenticatorImplementation {
    static func status(host: URL, headers: [HTTPHeader], pinnedCertificateSHA256: String?) async throws -> ServerStatus { throw APIError.unreachable }
    static func login(host: URL, headers: [HTTPHeader], username: String, password: String, pinnedCertificateSHA256: String?) async throws -> LoginResult { throw APIError.unreachable }
    static func beginOpenID(host: URL, headers: [HTTPHeader], pinnedCertificateSHA256: String?) async throws -> OpenIDAuthorization { throw APIError.unreachable }
    static func completeOpenID(host: URL, headers: [HTTPHeader], callbackURL: URL, codeVerifier: String, pinnedCertificateSHA256: String?) async throws -> LoginResult { throw APIError.unreachable }
}

final class APIClient: AudiobookshelfClient {
    let connection: Connection
    let tokenStore: any TokenStore
    nonisolated(unsafe) weak var delegate: (any APIClientDelegate)?

    init(connection: Connection, tokenStore: any TokenStore, delegate: (any APIClientDelegate)?) {
        self.connection = connection
        self.tokenStore = tokenStore
        self.delegate = delegate
    }

    func me() async throws -> (userID: String, username: String) { throw APIError.unreachable }
    func authorize() async throws -> AuthorizeResponse { throw APIError.unreachable }
    func libraries() async throws -> [Library] { throw APIError.unreachable }
    func filterData(library: LibraryIdentifier) async throws -> LibraryFilterData { throw APIError.unreachable }
    func home(library: Library) async throws -> [HomeRow] { throw APIError.unreachable }
    func recentEpisodes(library: LibraryIdentifier, limit: Int) async throws -> [Episode] { throw APIError.unreachable }
    func audiobooks(library: LibraryIdentifier, sort: AudiobookSortOrder?, direction: SortDirection, filter: LibraryItemFilter?, collapseSeries: Bool, page: Int, limit: Int) async throws -> Page<LibraryEntry> { throw APIError.unreachable }
    func podcasts(library: LibraryIdentifier, sort: PodcastSortOrder, direction: SortDirection, page: Int, limit: Int) async throws -> Page<Podcast> { throw APIError.unreachable }
    func series(library: LibraryIdentifier, sort: SeriesSortOrder, direction: SortDirection, filter: LibraryItemFilter?, page: Int, limit: Int) async throws -> Page<Series> { throw APIError.unreachable }
    func authors(library: LibraryIdentifier, sort: AuthorSortOrder, direction: SortDirection, page: Int, limit: Int) async throws -> Page<Person> { throw APIError.unreachable }
    func narrators(library: LibraryIdentifier) async throws -> [Person] { throw APIError.unreachable }
    func collections(library: LibraryIdentifier, page: Int, limit: Int) async throws -> Page<ItemCollection> { throw APIError.unreachable }
    func playlists(library: LibraryIdentifier, page: Int, limit: Int) async throws -> Page<ItemCollection> { throw APIError.unreachable }
    func search(library: LibraryIdentifier, query: String, limit: Int) async throws -> SearchResults { throw APIError.unreachable }
    func audiobook(_ id: ItemIdentifier) async throws -> Audiobook { throw APIError.unreachable }
    func podcast(_ id: ItemIdentifier) async throws -> (podcast: Podcast, episodes: [Episode]) { throw APIError.unreachable }
    func episode(_ id: ItemIdentifier) async throws -> Episode { throw APIError.unreachable }
    func playableDetails(_ id: ItemIdentifier) async throws -> PlayableItemDetails { throw APIError.unreachable }
    func author(_ id: ItemIdentifier) async throws -> (author: Person, audiobooks: [Audiobook], series: [Series]) { throw APIError.unreachable }
    func narrator(_ id: ItemIdentifier) async throws -> (narrator: Person, audiobooks: [Audiobook]) { throw APIError.unreachable }
    func seriesDetails(_ id: ItemIdentifier) async throws -> Series { throw APIError.unreachable }
    func collection(_ id: ItemIdentifier) async throws -> ItemCollection { throw APIError.unreachable }
    func updateEpisodeType(_ id: ItemIdentifier, type: Episode.EpisodeType) async throws { throw APIError.unreachable }
    func createCollection(name: String, library: LibraryIdentifier, items: [ItemIdentifier], playlist: Bool) async throws -> ItemIdentifier { throw APIError.unreachable }
    func updateCollection(_ id: ItemIdentifier, name: String?, description: String?, items: [ItemIdentifier]?) async throws { throw APIError.unreachable }
    func addToCollection(_ id: ItemIdentifier, items: [ItemIdentifier]) async throws { throw APIError.unreachable }
    func removeFromCollection(_ id: ItemIdentifier, items: [ItemIdentifier]) async throws { throw APIError.unreachable }
    func deleteCollection(_ id: ItemIdentifier) async throws { throw APIError.unreachable }
    func createPlaylist(fromCollection id: ItemIdentifier) async throws -> ItemIdentifier { throw APIError.unreachable }
    func startSession(_ id: ItemIdentifier, device: DeviceInfo) async throws -> PlaybackSessionInfo { throw APIError.unreachable }
    func syncSession(_ sessionID: String, currentTime: TimeInterval, duration: TimeInterval, timeListened: TimeInterval) async throws { throw APIError.unreachable }
    func closeSession(_ sessionID: String, currentTime: TimeInterval, duration: TimeInterval, timeListened: TimeInterval) async throws { throw APIError.unreachable }
    func uploadLocalSession(_ session: LocalSessionUpload, device: DeviceInfo) async throws { throw APIError.unreachable }
    func listeningSessions(page: Int, perPage: Int) async throws -> Page<ListeningSession> { throw APIError.unreachable }
    func listeningSessions(for id: ItemIdentifier, page: Int, perPage: Int) async throws -> Page<ListeningSession> { throw APIError.unreachable }
    func listeningStats() async throws -> ListeningStats { throw APIError.unreachable }
    func batchUpdateProgress(_ entries: [ProgressEntity]) async throws { throw APIError.unreachable }
    func deleteProgress(id: String) async throws { throw APIError.unreachable }
    func setFinished(_ id: ItemIdentifier, finished: Bool) async throws { throw APIError.unreachable }
    func hideFromContinueListening(progressID: String) async throws { throw APIError.unreachable }
    func createBookmark(_ id: ItemIdentifier, time: Int, note: String) async throws -> Bookmark { throw APIError.unreachable }
    func updateBookmark(_ id: ItemIdentifier, time: Int, note: String) async throws { throw APIError.unreachable }
    func deleteBookmark(_ id: ItemIdentifier, time: Int) async throws { throw APIError.unreachable }
    func coverRequest(for id: ItemIdentifier, size: ImageSize) async throws -> URLRequest { throw APIError.unreachable }
    func audioFileRequest(for id: ItemIdentifier, ino: String) async throws -> URLRequest { throw APIError.unreachable }
    func pdfRequest(for id: ItemIdentifier, ino: String) async throws -> URLRequest { throw APIError.unreachable }
    func streamingHeaders() async throws -> [String: String] { throw APIError.unreachable }
    func webURL(for id: ItemIdentifier) -> URL { connection.host }
    func events() -> AsyncStream<ServerEvent> { AsyncStream { $0.finish() } }
    func connectSocket() async {}
    func disconnectSocket() async {}
}
