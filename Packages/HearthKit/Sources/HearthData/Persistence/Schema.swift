import Foundation
import SwiftData

// MARK: - Schema v1

/// First version of Hearth's on-device database.
///
/// Every entity stores identifiers as strings (`ItemIdentifier.description` / `storageKey`) and enums as raw
/// strings so the schema stays stable when model types evolve. Rich values (items, rules) are stored as JSON.
enum HearthSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            StoredItem.self,
            StoredAsset.self,
            StoredChapter.self,
            StoredBookmark.self,
            StoredProgress.self,
            StoredLocalSession.self,
            StoredSetting.self,
            StoredKnownServer.self,
            StoredAutoDownloadRule.self,
            StoredAutoDownloadedItem.self,
        ]
    }

    /// Cached or downloaded audiobook, podcast or episode.
    @Model
    final class StoredItem {
        #Index<StoredItem>([\.kind], [\.connectionID], [\.isDownloaded], [\.groupingID])

        @Attribute(.unique) var key: String
        var identifier: String
        var kind: String
        var connectionID: String
        var libraryID: String
        var primaryID: String
        var groupingID: String?
        var name: String
        /// Normalised name + authors (+ podcast name) for local search.
        var searchText: String
        /// JSON encoded `AnyItem`.
        var payload: Data
        var isDownloaded: Bool
        var downloadCompletedAt: Date?
        var updatedAt: Date

        init(key: String, identifier: String, kind: String, connectionID: String, libraryID: String, primaryID: String, groupingID: String?, name: String, searchText: String, payload: Data, isDownloaded: Bool, downloadCompletedAt: Date?, updatedAt: Date) {
            self.key = key
            self.identifier = identifier
            self.kind = kind
            self.connectionID = connectionID
            self.libraryID = libraryID
            self.primaryID = primaryID
            self.groupingID = groupingID
            self.name = name
            self.searchText = searchText
            self.payload = payload
            self.isDownloaded = isDownloaded
            self.downloadCompletedAt = downloadCompletedAt
            self.updatedAt = updatedAt
        }
    }

    /// A file belonging to a download (audio track, PDF or cover).
    @Model
    final class StoredAsset {
        #Index<StoredAsset>([\.itemKey], [\.connectionID], [\.taskIdentifier])

        @Attribute(.unique) var id: String
        var itemKey: String
        var identifier: String
        var connectionID: String
        /// `audio`, `pdf` or `cover`.
        var kind: String
        /// Path relative to the downloads root.
        var relativePath: String
        var ino: String?
        var index: Int
        var offset: Double
        var duration: Double
        var mimeType: String?
        var fileExtension: String?
        var imageSize: Int?
        var isDownloaded: Bool
        var taskIdentifier: Int?
        var weight: Double
        var failureCount: Int
        var byteCount: Int64

        init(id: String, itemKey: String, identifier: String, connectionID: String, kind: String, relativePath: String, ino: String?, index: Int, offset: Double, duration: Double, mimeType: String?, fileExtension: String?, imageSize: Int?, isDownloaded: Bool, taskIdentifier: Int?, weight: Double, failureCount: Int, byteCount: Int64) {
            self.id = id
            self.itemKey = itemKey
            self.identifier = identifier
            self.connectionID = connectionID
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

    @Model
    final class StoredChapter {
        #Index<StoredChapter>([\.itemKey])

        @Attribute(.unique) var key: String
        var itemKey: String
        var chapterID: Int
        var start: Double
        var end: Double
        var title: String

        init(key: String, itemKey: String, chapterID: Int, start: Double, end: Double, title: String) {
            self.key = key
            self.itemKey = itemKey
            self.chapterID = chapterID
            self.start = start
            self.end = end
            self.title = title
        }
    }

    @Model
    final class StoredBookmark {
        #Index<StoredBookmark>([\.itemKey], [\.connectionID])

        /// `itemKey#time`.
        @Attribute(.unique) var key: String
        var itemKey: String
        var identifier: String
        var connectionID: String
        var time: Int
        var note: String
        var created: Date
        /// `BookmarkSyncStatus` raw value.
        var status: String

        init(key: String, itemKey: String, identifier: String, connectionID: String, time: Int, note: String, created: Date, status: String) {
            self.key = key
            self.itemKey = itemKey
            self.identifier = identifier
            self.connectionID = connectionID
            self.time = time
            self.note = note
            self.created = created
            self.status = status
        }
    }

    @Model
    final class StoredProgress {
        #Index<StoredProgress>([\.connectionID], [\.status])

        @Attribute(.unique) var key: String
        var identifier: String
        var connectionID: String
        var progressID: String
        var hasServerID: Bool
        var progress: Double
        var duration: Double?
        var currentTime: Double
        var startedAt: Date?
        var lastUpdate: Date
        var finishedAt: Date?
        var hideFromContinueListening: Bool
        /// `SyncStatus` raw value.
        var status: String

        init(key: String, identifier: String, connectionID: String, progressID: String, hasServerID: Bool, progress: Double, duration: Double?, currentTime: Double, startedAt: Date?, lastUpdate: Date, finishedAt: Date?, hideFromContinueListening: Bool, status: String) {
            self.key = key
            self.identifier = identifier
            self.connectionID = connectionID
            self.progressID = progressID
            self.hasServerID = hasServerID
            self.progress = progress
            self.duration = duration
            self.currentTime = currentTime
            self.startedAt = startedAt
            self.lastUpdate = lastUpdate
            self.finishedAt = finishedAt
            self.hideFromContinueListening = hideFromContinueListening
            self.status = status
        }
    }

    /// Listening session recorded while the server could not be reached.
    @Model
    final class StoredLocalSession {
        @Attribute(.unique) var id: String
        var identifier: String
        var connectionID: String
        var startTime: Double
        var currentTime: Double
        var duration: Double
        var timeListened: Double
        var startedAt: Date
        var updatedAt: Date
        var isClosed: Bool

        init(id: String, identifier: String, connectionID: String, startTime: Double, currentTime: Double, duration: Double, timeListened: Double, startedAt: Date, updatedAt: Date, isClosed: Bool) {
            self.id = id
            self.identifier = identifier
            self.connectionID = connectionID
            self.startTime = startTime
            self.currentTime = currentTime
            self.duration = duration
            self.timeListened = timeListened
            self.startedAt = startedAt
            self.updatedAt = updatedAt
            self.isClosed = isClosed
        }
    }

    /// Per-item key/value settings (`<itemKey>|<name>`), JSON values.
    @Model
    final class StoredSetting {
        @Attribute(.unique) var key: String
        var value: Data
        var updatedAt: Date

        init(key: String, value: Data, updatedAt: Date) {
            self.key = key
            self.value = value
            self.updatedAt = updatedAt
        }
    }

    @Model
    final class StoredKnownServer {
        @Attribute(.unique) var key: String
        var host: String
        var username: String
        var lastUsed: Date

        init(key: String, host: String, username: String, lastUsed: Date) {
            self.key = key
            self.host = host
            self.username = username
            self.lastUsed = lastUsed
        }
    }

    @Model
    final class StoredAutoDownloadRule {
        /// Grouping storage key, or `AutoDownloadRuleKey.listenNow`.
        @Attribute(.unique) var key: String
        /// `ItemIdentifier.description` of the grouping (empty for Listen Now).
        var identifier: String
        var connectionID: String
        /// JSON encoded `AutoDownloadRule`.
        var rule: Data
        var createdAt: Date

        init(key: String, identifier: String, connectionID: String, rule: Data, createdAt: Date) {
            self.key = key
            self.identifier = identifier
            self.connectionID = connectionID
            self.rule = rule
            self.createdAt = createdAt
        }
    }

    /// Records which rule downloaded which item (so they can be removed when no rule covers them anymore).
    @Model
    final class StoredAutoDownloadedItem {
        #Index<StoredAutoDownloadedItem>([\.ruleKey], [\.itemKey])

        @Attribute(.unique) var key: String
        var ruleKey: String
        var itemKey: String
        var identifier: String
        var connectionID: String
        var downloadedAt: Date

        init(key: String, ruleKey: String, itemKey: String, identifier: String, connectionID: String, downloadedAt: Date) {
            self.key = key
            self.ruleKey = ruleKey
            self.itemKey = itemKey
            self.identifier = identifier
            self.connectionID = connectionID
            self.downloadedAt = downloadedAt
        }
    }
}

// Current schema aliases.
typealias StoredItem = HearthSchemaV1.StoredItem
typealias StoredAsset = HearthSchemaV1.StoredAsset
typealias StoredChapter = HearthSchemaV1.StoredChapter
typealias StoredBookmark = HearthSchemaV1.StoredBookmark
typealias StoredProgress = HearthSchemaV1.StoredProgress
typealias StoredLocalSession = HearthSchemaV1.StoredLocalSession
typealias StoredSetting = HearthSchemaV1.StoredSetting
typealias StoredKnownServer = HearthSchemaV1.StoredKnownServer
typealias StoredAutoDownloadRule = HearthSchemaV1.StoredAutoDownloadRule
typealias StoredAutoDownloadedItem = HearthSchemaV1.StoredAutoDownloadedItem

enum HearthMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [HearthSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
