import Foundation

/// `GET status`.
struct StatusPayload: Decodable, Sendable {
    var isInit: Bool
    var authMethods: [String]
    var serverVersion: String?
    var openIDButtonText: String?
    var openIDAutoLaunch: Bool

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        isInit = c.bool("isInit") ?? false
        authMethods = c.strings("authMethods")
        serverVersion = c.nonEmptyString("serverVersion")
        let form = c.decode("authFormData", as: AuthFormDataPayload.self)
        openIDButtonText = form?.buttonText
        openIDAutoLaunch = form?.autoLaunch ?? false
    }
}

struct AuthFormDataPayload: Decodable, Sendable {
    var buttonText: String?
    var autoLaunch: Bool

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        buttonText = c.nonEmptyString("authOpenIDButtonText")
        autoLaunch = c.bool("authOpenIDAutoLaunch") ?? false
    }
}

/// Wrapper of login / refresh / authorize / OpenID callback responses.
struct UserResponsePayload: Decodable, Sendable {
    var user: UserPayload
}

struct UserPayload: Decodable, Sendable {
    var id: String
    var username: String
    /// Short lived JWT (server 2.26+).
    var accessToken: String?
    /// Legacy non-expiring token.
    var token: String?
    var refreshToken: String?
    var mediaProgress: [MediaProgressPayload]
    var bookmarks: [BookmarkPayload]

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        id = c.string("id") ?? ""
        username = c.string("username") ?? ""
        accessToken = c.nonEmptyString("accessToken")
        token = c.nonEmptyString("token")
        refreshToken = c.nonEmptyString("refreshToken")
        mediaProgress = c.array("mediaProgress")
        bookmarks = c.array("bookmarks")
    }

    /// `accessToken` with fallback to the legacy `token`.
    var bestAccessToken: String? { accessToken ?? token }
}

struct MediaProgressPayload: Decodable, Sendable {
    var id: String
    var libraryItemID: String
    var episodeID: String?
    var duration: Double?
    var progress: Double
    var currentTime: Double
    var isFinished: Bool
    var hideFromContinueListening: Bool
    var lastUpdate: Date?
    var startedAt: Date?
    var finishedAt: Date?

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        guard let id = c.nonEmptyString("id"), let libraryItemID = c.nonEmptyString("libraryItemId") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Progress without id or libraryItemId"))
        }
        self.id = id
        self.libraryItemID = libraryItemID
        episodeID = c.nonEmptyString("episodeId")
        duration = c.double("duration")
        progress = c.double("progress") ?? 0
        currentTime = c.double("currentTime") ?? 0
        isFinished = c.bool("isFinished") ?? false
        hideFromContinueListening = c.bool("hideFromContinueListening") ?? false
        lastUpdate = c.dateMS("lastUpdate")
        startedAt = c.dateMS("startedAt")
        finishedAt = c.dateMS("finishedAt")
    }
}

struct BookmarkPayload: Decodable, Sendable {
    var libraryItemID: String
    var title: String
    var time: Double
    var createdAt: Date?

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        guard let libraryItemID = c.nonEmptyString("libraryItemId"), let time = c.double("time") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bookmark without item or time"))
        }
        self.libraryItemID = libraryItemID
        self.time = time
        title = c.string("title") ?? ""
        createdAt = c.dateMS("createdAt")
    }
}

/// Socket.IO `user_item_progress_updated` payload.
struct ProgressUpdatedEventPayload: Decodable, Sendable {
    var data: MediaProgressPayload
}

/// `{id, libraryId}` – socket `item_removed`.
struct ItemReferencePayload: Decodable, Sendable {
    var id: String
    var libraryID: String?

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        guard let id = c.nonEmptyString("id") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Reference without id"))
        }
        self.id = id
        libraryID = c.nonEmptyString("libraryId")
    }
}
