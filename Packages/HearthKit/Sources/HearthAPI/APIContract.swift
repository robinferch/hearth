// CONTRACT FILE – public surface of HearthAPI.
// Signatures in this file are relied upon by HearthData, HearthPlayback and the apps.
// Implementations may move into other files, but public names/signatures must stay compatible
// (adding members / default parameters is fine).

import Foundation
import HearthModel

public enum APIError: Error, Sendable, Equatable {
    case offline
    case unreachable
    case unauthorized
    case notFound
    case invalidURL
    case invalidResponse(statusCode: Int)
    case decoding(String)
    case transport(String)
    case cancelled
    case serverNotInitialized
    case unsupportedAuthMethod
    case untrustedCertificate(sha256: String)
}

/// Persists and supplies tokens for a connection. Implemented by HearthData (Keychain).
public protocol TokenStore: Sendable {
    func tokens(for connectionID: ConnectionID) async -> AuthTokens?
    func store(_ tokens: AuthTokens, for connectionID: ConnectionID) async
}

/// Notified when a connection's refresh token was rejected (user must re-authenticate).
public protocol APIClientDelegate: AnyObject, Sendable {
    func apiClientDidBecomeUnauthorized(_ connectionID: ConnectionID) async
}

/// Global switches shared by all clients.
public final class APINetworkPolicy: @unchecked Sendable {
    public static let shared = APINetworkPolicy()

    private let lock = NSLock()
    private var _isOffline = false

    public var isOffline: Bool {
        get { lock.withLock { _isOffline } }
        set { lock.withLock { _isOffline = newValue } }
    }
}

public struct DeviceInfo: Hashable, Codable, Sendable {
    public var deviceID: String
    public var clientName: String
    public var clientVersion: String
    public var manufacturer: String
    public var model: String
    public var osName: String
    public var osVersion: String

    public init(deviceID: String, clientName: String = "Hearth", clientVersion: String, manufacturer: String = "Apple", model: String, osName: String, osVersion: String) {
        self.deviceID = deviceID
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.manufacturer = manufacturer
        self.model = model
        self.osName = osName
        self.osVersion = osVersion
    }
}

/// Everything needed to play or download a book/episode.
public struct PlayableItemDetails: Sendable, Hashable {
    public var item: AnyPlayableItem
    public var audioFiles: [AudioFile]
    public var chapters: [Chapter]
    public var pdfs: [PDFFile]
    /// Server progress included in the expanded item response, if any.
    public var progress: ProgressEntity?

    public init(item: AnyPlayableItem, audioFiles: [AudioFile], chapters: [Chapter], pdfs: [PDFFile], progress: ProgressEntity?) {
        self.item = item
        self.audioFiles = audioFiles
        self.chapters = chapters
        self.pdfs = pdfs
        self.progress = progress
    }
}

public struct PlaybackSessionInfo: Sendable, Hashable {
    public var id: String
    public var startTime: TimeInterval
    public var duration: TimeInterval
    /// Absolute streaming URLs; play with `APIClient.streamingHeaders()`.
    public var tracks: [AudioTrack]
    public var chapters: [Chapter]

    public init(id: String, startTime: TimeInterval, duration: TimeInterval, tracks: [AudioTrack], chapters: [Chapter]) {
        self.id = id
        self.startTime = startTime
        self.duration = duration
        self.tracks = tracks
        self.chapters = chapters
    }
}

/// A session recorded while offline, uploaded via `api/session/local`.
public struct LocalSessionUpload: Sendable, Hashable {
    public var id: String
    public var itemID: ItemIdentifier
    public var startTime: TimeInterval
    public var currentTime: TimeInterval
    public var duration: TimeInterval
    public var timeListened: TimeInterval
    public var startedAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, itemID: ItemIdentifier, startTime: TimeInterval, currentTime: TimeInterval, duration: TimeInterval, timeListened: TimeInterval, startedAt: Date, updatedAt: Date) {
        self.id = id
        self.itemID = itemID
        self.startTime = startTime
        self.currentTime = currentTime
        self.duration = duration
        self.timeListened = timeListened
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }
}

public struct ListeningSession: Sendable, Hashable, Identifiable {
    public var id: String
    public var itemID: ItemIdentifier?
    public var displayTitle: String?
    public var timeListening: TimeInterval
    public var startTime: TimeInterval
    public var currentTime: TimeInterval
    public var startedAt: Date
    public var updatedAt: Date
    public var deviceName: String?

    public init(id: String, itemID: ItemIdentifier?, displayTitle: String?, timeListening: TimeInterval, startTime: TimeInterval, currentTime: TimeInterval, startedAt: Date, updatedAt: Date, deviceName: String?) {
        self.id = id
        self.itemID = itemID
        self.displayTitle = displayTitle
        self.timeListening = timeListening
        self.startTime = startTime
        self.currentTime = currentTime
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.deviceName = deviceName
    }
}

public struct ListeningStats: Sendable, Hashable {
    /// Seconds listened per day, keyed by `yyyy-MM-dd`.
    public var days: [String: TimeInterval]
    public var totalTime: TimeInterval
    public var today: TimeInterval
    /// (library item id, title, seconds) of the most listened items.
    public var topItems: [TopItem]

    public struct TopItem: Sendable, Hashable, Identifiable {
        public var id: String
        public var title: String
        public var timeListening: TimeInterval

        public init(id: String, title: String, timeListening: TimeInterval) {
            self.id = id
            self.title = title
            self.timeListening = timeListening
        }
    }

    public init(days: [String: TimeInterval], totalTime: TimeInterval, today: TimeInterval, topItems: [TopItem]) {
        self.days = days
        self.totalTime = totalTime
        self.today = today
        self.topItems = topItems
    }
}

public struct AuthorizeResponse: Sendable {
    public var userID: String
    public var username: String
    public var progress: [ProgressEntity]
    public var bookmarks: [Bookmark]
    /// Library item ids (`ItemIdentifier.apiItemID`) whose progress/bookmarks are missing from `progress` and
    /// `bookmarks` because their library couldn't be looked up (request failed). The server still has those
    /// entries, so they must not be treated as deleted remotely.
    public var unresolvedItemIDs: Set<String>

    public init(userID: String, username: String, progress: [ProgressEntity], bookmarks: [Bookmark], unresolvedItemIDs: Set<String> = []) {
        self.userID = userID
        self.username = username
        self.progress = progress
        self.bookmarks = bookmarks
        self.unresolvedItemIDs = unresolvedItemIDs
    }
}

public struct LoginResult: Sendable {
    public var tokens: AuthTokens
    public var username: String
    public var userID: String

    public init(tokens: AuthTokens, username: String, userID: String) {
        self.tokens = tokens
        self.username = username
        self.userID = userID
    }
}

/// Live events delivered over the Socket.IO connection.
public enum ServerEvent: Sendable {
    case progressUpdated(ProgressEntity)
    case itemUpdated(ItemIdentifier)
    case itemAdded(LibraryIdentifier)
    case itemRemoved(ItemIdentifier)
    case userUpdated
    case connected
    case disconnected
}

public struct OpenIDAuthorization: Sendable {
    /// Open in `ASWebAuthenticationSession` with callback scheme `hearth`.
    public var authorizationURL: URL
    public var codeVerifier: String

    public init(authorizationURL: URL, codeVerifier: String) {
        self.authorizationURL = authorizationURL
        self.codeVerifier = codeVerifier
    }
}

/// Unauthenticated server operations used while adding a connection.
public enum ServerAuthenticator {
    public static let callbackScheme = "hearth"
    public static let callbackURL = "hearth://oauth"

    public static func status(host: URL, headers: [HTTPHeader], pinnedCertificateSHA256: String? = nil) async throws -> ServerStatus {
        try await AuthenticatorImplementation.status(host: host, headers: headers, pinnedCertificateSHA256: pinnedCertificateSHA256)
    }

    public static func login(host: URL, headers: [HTTPHeader], username: String, password: String, pinnedCertificateSHA256: String? = nil) async throws -> LoginResult {
        try await AuthenticatorImplementation.login(host: host, headers: headers, username: username, password: password, pinnedCertificateSHA256: pinnedCertificateSHA256)
    }

    public static func beginOpenID(host: URL, headers: [HTTPHeader], pinnedCertificateSHA256: String? = nil) async throws -> OpenIDAuthorization {
        try await AuthenticatorImplementation.beginOpenID(host: host, headers: headers, pinnedCertificateSHA256: pinnedCertificateSHA256)
    }

    public static func completeOpenID(host: URL, headers: [HTTPHeader], callbackURL: URL, codeVerifier: String, pinnedCertificateSHA256: String? = nil) async throws -> LoginResult {
        try await AuthenticatorImplementation.completeOpenID(host: host, headers: headers, callbackURL: callbackURL, codeVerifier: codeVerifier, pinnedCertificateSHA256: pinnedCertificateSHA256)
    }
}

/// One client per connection. Thread-safe.
public protocol AudiobookshelfClient: Sendable {
    var connection: Connection { get }

    // MARK: Account
    func me() async throws -> (userID: String, username: String)
    func authorize() async throws -> AuthorizeResponse

    // MARK: Libraries
    func libraries() async throws -> [Library]
    func filterData(library: LibraryIdentifier) async throws -> LibraryFilterData
    func home(library: Library) async throws -> [HomeRow]
    func recentEpisodes(library: LibraryIdentifier, limit: Int) async throws -> [Episode]

    // MARK: Lists
    func audiobooks(library: LibraryIdentifier, sort: AudiobookSortOrder?, direction: SortDirection, filter: LibraryItemFilter?, collapseSeries: Bool, page: Int, limit: Int) async throws -> Page<LibraryEntry>
    func podcasts(library: LibraryIdentifier, sort: PodcastSortOrder, direction: SortDirection, page: Int, limit: Int) async throws -> Page<Podcast>
    func series(library: LibraryIdentifier, sort: SeriesSortOrder, direction: SortDirection, filter: LibraryItemFilter?, page: Int, limit: Int) async throws -> Page<Series>
    func authors(library: LibraryIdentifier, sort: AuthorSortOrder, direction: SortDirection, page: Int, limit: Int) async throws -> Page<Person>
    func narrators(library: LibraryIdentifier) async throws -> [Person]
    func collections(library: LibraryIdentifier, page: Int, limit: Int) async throws -> Page<ItemCollection>
    func playlists(library: LibraryIdentifier, page: Int, limit: Int) async throws -> Page<ItemCollection>
    func search(library: LibraryIdentifier, query: String, limit: Int) async throws -> SearchResults

    // MARK: Single items
    func audiobook(_ id: ItemIdentifier) async throws -> Audiobook
    func podcast(_ id: ItemIdentifier) async throws -> (podcast: Podcast, episodes: [Episode])
    func episode(_ id: ItemIdentifier) async throws -> Episode
    func playableDetails(_ id: ItemIdentifier) async throws -> PlayableItemDetails
    func author(_ id: ItemIdentifier) async throws -> (author: Person, audiobooks: [Audiobook], series: [Series])
    func narrator(_ id: ItemIdentifier) async throws -> (narrator: Person, audiobooks: [Audiobook])
    func seriesDetails(_ id: ItemIdentifier) async throws -> Series
    func collection(_ id: ItemIdentifier) async throws -> ItemCollection
    func updateEpisodeType(_ id: ItemIdentifier, type: Episode.EpisodeType) async throws

    // MARK: Collections & playlists
    func createCollection(name: String, library: LibraryIdentifier, items: [ItemIdentifier], playlist: Bool) async throws -> ItemIdentifier
    func updateCollection(_ id: ItemIdentifier, name: String?, description: String?, items: [ItemIdentifier]?) async throws
    func addToCollection(_ id: ItemIdentifier, items: [ItemIdentifier]) async throws
    func removeFromCollection(_ id: ItemIdentifier, items: [ItemIdentifier]) async throws
    func deleteCollection(_ id: ItemIdentifier) async throws
    func createPlaylist(fromCollection id: ItemIdentifier) async throws -> ItemIdentifier

    // MARK: Sessions
    func startSession(_ id: ItemIdentifier, device: DeviceInfo) async throws -> PlaybackSessionInfo
    func syncSession(_ sessionID: String, currentTime: TimeInterval, duration: TimeInterval, timeListened: TimeInterval) async throws
    func closeSession(_ sessionID: String, currentTime: TimeInterval, duration: TimeInterval, timeListened: TimeInterval) async throws
    func uploadLocalSession(_ session: LocalSessionUpload, device: DeviceInfo) async throws
    func listeningSessions(page: Int, perPage: Int) async throws -> Page<ListeningSession>
    func listeningSessions(for id: ItemIdentifier, page: Int, perPage: Int) async throws -> Page<ListeningSession>
    func listeningStats() async throws -> ListeningStats

    // MARK: Progress
    func batchUpdateProgress(_ entries: [ProgressEntity]) async throws
    func deleteProgress(id: String) async throws
    func setFinished(_ id: ItemIdentifier, finished: Bool) async throws
    func hideFromContinueListening(progressID: String) async throws

    // MARK: Bookmarks
    func createBookmark(_ id: ItemIdentifier, time: Int, note: String) async throws -> Bookmark
    func updateBookmark(_ id: ItemIdentifier, time: Int, note: String) async throws
    func deleteBookmark(_ id: ItemIdentifier, time: Int) async throws

    // MARK: Files
    func coverRequest(for id: ItemIdentifier, size: ImageSize) async throws -> URLRequest
    func audioFileRequest(for id: ItemIdentifier, ino: String) async throws -> URLRequest
    func pdfRequest(for id: ItemIdentifier, ino: String) async throws -> URLRequest
    /// Headers (custom + bearer) for AVURLAsset streaming.
    func streamingHeaders() async throws -> [String: String]
    func webURL(for id: ItemIdentifier) -> URL

    // MARK: Live updates
    func events() -> AsyncStream<ServerEvent>
    func connectSocket() async
    func disconnectSocket() async
}

public enum APIClientFactory {
    /// Creates the production client for a connection.
    public static func makeClient(connection: Connection, tokenStore: any TokenStore, delegate: (any APIClientDelegate)?) -> any AudiobookshelfClient {
        APIClient(connection: connection, tokenStore: tokenStore, delegate: delegate)
    }
}
