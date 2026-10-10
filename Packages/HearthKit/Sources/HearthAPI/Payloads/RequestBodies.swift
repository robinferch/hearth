import Foundation
import HearthModel

/// `deviceInfo` object sent when starting or uploading sessions.
struct DeviceInfoBody: Encodable, Sendable {
    var deviceId: String
    var clientName: String
    var clientVersion: String
    var manufacturer: String
    var model: String
    var osName: String?
    var osVersion: String?

    init(_ device: DeviceInfo, includeOS: Bool) {
        deviceId = device.deviceID
        clientName = device.clientName
        clientVersion = device.clientVersion
        manufacturer = device.manufacturer
        model = device.model
        osName = includeOS ? device.osName : nil
        osVersion = includeOS ? device.osVersion : nil
    }
}

struct LoginBody: Encodable, Sendable {
    var username: String
    var password: String
}

struct StartSessionBody: Encodable, Sendable {
    static let supportedMimeTypes = ["audio/flac", "audio/mpeg", "audio/mp4", "audio/aac", "audio/x-aiff", "audio/x-m4a", "audio/x-m4b"]

    var deviceInfo: DeviceInfoBody
    var supportedMimeTypes = Self.supportedMimeTypes
    var mediaPlayer = "AVPlayer"
    var forceDirectPlay = true
}

struct SessionSyncBody: Encodable, Sendable {
    var duration: Double
    var currentTime: Double
    var timeListened: Double
}

/// Body of `POST api/session/local`.
struct LocalSessionBody: Encodable, Sendable {
    var id: String
    var userId: String?
    var libraryId: String
    var libraryItemId: String
    var episodeId: String?
    var mediaType: String
    var mediaMetadata: [String: String]?
    var chapters: [ChapterBody]
    var displayTitle: String?
    var displayAuthor: String?
    var coverPath: String?
    var duration: Double
    var playMethod = 3
    var mediaPlayer = "AVPlayer"
    var deviceInfo: DeviceInfoBody
    var date: String
    var dayOfWeek: String
    var timeListening: Double
    var startTime: Double
    var currentTime: Double
    var startedAt: Int64
    var updatedAt: Int64

    init(_ session: LocalSessionUpload, userID: String?, device: DeviceInfo, timeZone: TimeZone = .current) {
        id = session.id
        userId = userID
        libraryId = session.itemID.libraryID
        libraryItemId = session.itemID.apiItemID
        episodeId = session.itemID.apiEpisodeID
        mediaType = session.itemID.kind == .episode ? "podcast" : "book"
        chapters = []
        duration = session.duration
        deviceInfo = DeviceInfoBody(device, includeOS: true)
        date = Self.dayFormatter(timeZone: timeZone, format: "yyyy-MM-dd").string(from: session.startedAt)
        dayOfWeek = Self.dayFormatter(timeZone: timeZone, format: "EEEE").string(from: session.startedAt)
        timeListening = session.timeListened
        startTime = session.startTime
        currentTime = session.currentTime
        startedAt = session.startedAt.epochMilliseconds
        updatedAt = session.updatedAt.epochMilliseconds
    }

    private static func dayFormatter(timeZone: TimeZone, format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}

struct ChapterBody: Encodable, Sendable {
    var id: Int
    var start: Double
    var end: Double
    var title: String
}

/// Entry of `PATCH api/me/progress/batch/update`. `nil` values are omitted.
struct ProgressUpdateBody: Encodable, Sendable {
    var libraryItemId: String
    var episodeId: String?
    var duration: Double?
    var progress: Double
    var currentTime: Double
    var isFinished: Bool
    var hideFromContinueListening: Bool
    var lastUpdate: Int64
    var startedAt: Int64?
    var finishedAt: Int64?

    init(_ entity: ProgressEntity) {
        libraryItemId = entity.itemID.apiItemID
        episodeId = entity.itemID.apiEpisodeID
        duration = entity.duration
        progress = min(max(entity.progress, 0), 1)
        currentTime = entity.currentTime
        isFinished = entity.isFinished
        hideFromContinueListening = entity.hideFromContinueListening
        lastUpdate = entity.lastUpdate.epochMilliseconds
        startedAt = entity.startedAt?.epochMilliseconds
        finishedAt = entity.finishedAt?.epochMilliseconds
    }
}

struct FinishedBody: Encodable, Sendable {
    var isFinished: Bool
}

struct BookmarkBody: Encodable, Sendable {
    var title: String
    var time: Int
}

struct EpisodeTypeBody: Encodable, Sendable {
    var episodeType: String
}

struct PlaylistItemBody: Encodable, Sendable {
    var libraryItemId: String
    var episodeId: String?

    init(_ id: ItemIdentifier) {
        libraryItemId = id.apiItemID
        episodeId = id.apiEpisodeID
    }
}

struct CreateCollectionBody: Encodable, Sendable {
    var name: String
    var libraryId: String
    var books: [String]
}

struct CreatePlaylistBody: Encodable, Sendable {
    var name: String
    var libraryId: String
    var items: [PlaylistItemBody]
}

struct UpdateCollectionBody: Encodable, Sendable {
    var name: String?
    var description: String?
    var books: [String]?
}

struct UpdatePlaylistBody: Encodable, Sendable {
    var name: String?
    var description: String?
    var items: [PlaylistItemBody]?
}

struct CollectionBooksBody: Encodable, Sendable {
    var books: [String]
}

struct PlaylistItemsBody: Encodable, Sendable {
    var items: [PlaylistItemBody]
}

struct BatchGetBody: Encodable, Sendable {
    var libraryItemIds: [String]
}

extension Date {
    var epochMilliseconds: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }
}
