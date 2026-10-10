import Foundation
import HearthAPI
import HearthModel

/// Sync state of a local progress record.
enum SyncStatus: String, Codable, Sendable {
    case synced
    /// Changed locally, must be pushed.
    case dirty
    /// Reset locally, the server copy must be deleted.
    case tombstone
}

struct ProgressRecord: Sendable, Hashable {
    var entity: ProgressEntity
    var status: SyncStatus
    /// Whether `entity.id` is a server progress id.
    var hasServerID: Bool

    init(entity: ProgressEntity, status: SyncStatus, hasServerID: Bool) {
        self.entity = entity
        self.status = status
        self.hasServerID = hasServerID
    }
}

enum BookmarkSyncStatus: String, Codable, Sendable {
    case synced
    case pendingCreate
    case pendingUpdate
    case deleted
}

struct BookmarkRecord: Sendable, Hashable {
    var bookmark: Bookmark
    var status: BookmarkSyncStatus

    var key: String { BookmarkRecord.key(bookmark.itemID, time: bookmark.time) }

    static func key(_ itemID: ItemIdentifier, time: Int) -> String {
        "\(itemID.storageKey)#\(time)"
    }
}

enum AssetKind: String, Codable, Sendable {
    case audio
    case pdf
    case cover
}

struct DownloadAsset: Sendable, Hashable, Identifiable {
    var id: String
    var itemID: ItemIdentifier
    var kind: AssetKind
    var relativePath: String
    var ino: String?
    var index: Int
    var offset: TimeInterval
    var duration: TimeInterval
    var mimeType: String?
    var fileExtension: String?
    var imageSize: ImageSize?
    var isDownloaded: Bool
    var taskIdentifier: Int?
    var weight: Double
    var failureCount: Int
    var byteCount: Int64

    init(id: String = UUID().uuidString, itemID: ItemIdentifier, kind: AssetKind, relativePath: String, ino: String? = nil, index: Int = 0, offset: TimeInterval = 0, duration: TimeInterval = 0, mimeType: String? = nil, fileExtension: String? = nil, imageSize: ImageSize? = nil, isDownloaded: Bool = false, taskIdentifier: Int? = nil, weight: Double, failureCount: Int = 0, byteCount: Int64 = 0) {
        self.id = id
        self.itemID = itemID
        self.kind = kind
        self.relativePath = relativePath
        self.ino = ino
        self.index = index
        self.offset = offset
        self.duration = duration
        self.mimeType = mimeType
        self.fileExtension = fileExtension
        self.imageSize = imageSize
        self.isDownloaded = isDownloaded
        self.taskIdentifier = taskIdentifier
        self.weight = weight
        self.failureCount = failureCount
        self.byteCount = byteCount
    }
}

struct LocalSessionRecord: Sendable, Hashable, Identifiable {
    var id: String
    var itemID: ItemIdentifier
    var startTime: TimeInterval
    var currentTime: TimeInterval
    var duration: TimeInterval
    var timeListened: TimeInterval
    var startedAt: Date
    var updatedAt: Date
    var isClosed: Bool

    var upload: LocalSessionUpload {
        LocalSessionUpload(id: id, itemID: itemID, startTime: startTime, currentTime: currentTime, duration: duration, timeListened: timeListened, startedAt: startedAt, updatedAt: updatedAt)
    }
}

struct StoredItemValue: Sendable, Hashable {
    var item: AnyItem
    var isDownloaded: Bool
    var downloadCompletedAt: Date?
}

enum AutoDownloadRuleKey {
    static let listenNow = "listen-now"
}

struct AutoDownloadRuleRecord: Sendable, Hashable {
    /// `nil` for the Listen Now rule.
    var grouping: ItemIdentifier?
    var rule: AutoDownloadRule

    var key: String { grouping?.storageKey ?? AutoDownloadRuleKey.listenNow }
}

struct AutoDownloadedItemRecord: Sendable, Hashable {
    var ruleKey: String
    var itemID: ItemIdentifier
    var downloadedAt: Date
}
