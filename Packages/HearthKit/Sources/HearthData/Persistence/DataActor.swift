import Foundation
import HearthModel
import os
import SwiftData

/// Background actor that owns a `ModelContext` for all writes and bulk reads.
///
/// Callers use `perform { context in … }` with the typed helpers defined on `ModelContext` below and only ever
/// receive `Sendable` value types.
@ModelActor
actor DataActor {
    func perform<T: Sendable>(_ body: @Sendable (ModelContext) -> T) -> T {
        body(modelContext)
    }
}

enum Persistence {
    static let logger = Logger(category: "Persistence")

    static var storeURL: URL {
        AppGroup.directory("Library/Application Support").appending(path: "Hearth.store")
    }

    /// Creates the container. Corrupt or incompatible stores are deleted and recreated; as a last resort an
    /// in-memory store is used so the app keeps working.
    static func makeContainer(inMemory: Bool = false, url: URL? = nil) -> ModelContainer {
        let schema = Schema(versionedSchema: HearthSchemaV1.self)

        func make(memory: Bool) throws -> ModelContainer {
            let configuration: ModelConfiguration
            if memory {
                configuration = ModelConfiguration("Hearth-\(UUID().uuidString)", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            } else {
                configuration = ModelConfiguration("Hearth", schema: schema, url: url ?? storeURL, cloudKitDatabase: .none)
            }
            return try ModelContainer(for: schema, migrationPlan: HearthMigrationPlan.self, configurations: configuration)
        }

        if inMemory, let container = try? make(memory: true) {
            return container
        }

        do {
            return try make(memory: false)
        } catch {
            logger.error("Opening the store failed, recreating it: \(error.localizedDescription, privacy: .public)")
            let base = url ?? storeURL
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: base.path + suffix))
            }
            if let container = try? make(memory: false) {
                return container
            }
            logger.fault("Falling back to an in-memory store")
            // swiftlint:disable:next force_try
            return try! make(memory: true)
        }
    }
}

// MARK: - Typed operations

extension ModelContext {
    func commit() {
        guard hasChanges else { return }
        do {
            try save()
        } catch {
            Persistence.logger.error("Saving failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Progress

    func progressRecords(connectionID: ConnectionID? = nil) -> [ProgressRecord] {
        var descriptor = FetchDescriptor<StoredProgress>()
        if let connectionID {
            descriptor.predicate = #Predicate { $0.connectionID == connectionID }
        }
        let stored = (try? fetch(descriptor)) ?? []
        return stored.compactMap { stored in
            guard let itemID = ItemIdentifier(stored.identifier) else { return nil }
            let entity = ProgressEntity(id: stored.progressID, itemID: itemID, progress: stored.progress, duration: stored.duration, currentTime: stored.currentTime, startedAt: stored.startedAt, lastUpdate: stored.lastUpdate, finishedAt: stored.finishedAt, hideFromContinueListening: stored.hideFromContinueListening)
            return ProgressRecord(entity: entity, status: SyncStatus(rawValue: stored.status) ?? .dirty, hasServerID: stored.hasServerID)
        }
    }

    func upsertProgress(_ records: [ProgressRecord]) {
        for record in records {
            let key = record.entity.itemID.storageKey
            let entity = record.entity
            if let existing = try? fetch(FetchDescriptor<StoredProgress>(predicate: #Predicate { $0.key == key })).first {
                existing.identifier = entity.itemID.description
                existing.progressID = entity.id
                existing.hasServerID = record.hasServerID
                existing.progress = entity.progress
                existing.duration = entity.duration
                existing.currentTime = entity.currentTime
                existing.startedAt = entity.startedAt
                existing.lastUpdate = entity.lastUpdate
                existing.finishedAt = entity.finishedAt
                existing.hideFromContinueListening = entity.hideFromContinueListening
                existing.status = record.status.rawValue
            } else {
                insert(StoredProgress(key: key, identifier: entity.itemID.description, connectionID: entity.itemID.connectionID, progressID: entity.id, hasServerID: record.hasServerID, progress: entity.progress, duration: entity.duration, currentTime: entity.currentTime, startedAt: entity.startedAt, lastUpdate: entity.lastUpdate, finishedAt: entity.finishedAt, hideFromContinueListening: entity.hideFromContinueListening, status: record.status.rawValue))
            }
        }
        commit()
    }

    func deleteProgress(_ itemIDs: [ItemIdentifier]) {
        for itemID in itemIDs {
            let key = itemID.storageKey
            try? delete(model: StoredProgress.self, where: #Predicate { $0.key == key })
        }
        commit()
    }

    // MARK: Bookmarks

    func bookmarkRecords(connectionID: ConnectionID? = nil) -> [BookmarkRecord] {
        var descriptor = FetchDescriptor<StoredBookmark>()
        if let connectionID {
            descriptor.predicate = #Predicate { $0.connectionID == connectionID }
        }
        let stored = (try? fetch(descriptor)) ?? []
        return stored.compactMap { stored in
            guard let itemID = ItemIdentifier(stored.identifier) else { return nil }
            return BookmarkRecord(bookmark: Bookmark(itemID: itemID, time: stored.time, note: stored.note, created: stored.created), status: BookmarkSyncStatus(rawValue: stored.status) ?? .pendingCreate)
        }
    }

    func upsertBookmarks(_ records: [BookmarkRecord]) {
        for record in records {
            let key = record.key
            if let existing = try? fetch(FetchDescriptor<StoredBookmark>(predicate: #Predicate { $0.key == key })).first {
                existing.note = record.bookmark.note
                existing.created = record.bookmark.created
                existing.status = record.status.rawValue
            } else {
                let bookmark = record.bookmark
                insert(StoredBookmark(key: key, itemKey: bookmark.itemID.storageKey, identifier: bookmark.itemID.description, connectionID: bookmark.itemID.connectionID, time: bookmark.time, note: bookmark.note, created: bookmark.created, status: record.status.rawValue))
            }
        }
        commit()
    }

    func deleteBookmarks(keys: [String]) {
        for key in keys {
            try? delete(model: StoredBookmark.self, where: #Predicate { $0.key == key })
        }
        commit()
    }

    // MARK: Items

    private func value(_ stored: StoredItem) -> StoredItemValue? {
        guard let item = JSON.decode(AnyItem.self, from: stored.payload) else { return nil }
        return StoredItemValue(item: item, isDownloaded: stored.isDownloaded, downloadCompletedAt: stored.downloadCompletedAt)
    }

    func storedItem(_ id: ItemIdentifier) -> StoredItemValue? {
        let key = id.storageKey
        guard let stored = try? fetch(FetchDescriptor<StoredItem>(predicate: #Predicate { $0.key == key })).first else { return nil }
        return value(stored)
    }

    func storedItems(downloadedOnly: Bool, kind: ItemIdentifier.Kind? = nil, groupingID: String? = nil) -> [StoredItemValue] {
        var descriptor = FetchDescriptor<StoredItem>()
        switch (downloadedOnly, kind?.rawValue, groupingID) {
        case (true, let kind?, let grouping?):
            descriptor.predicate = #Predicate { $0.isDownloaded && $0.kind == kind && $0.groupingID == grouping }
        case (true, let kind?, nil):
            descriptor.predicate = #Predicate { $0.isDownloaded && $0.kind == kind }
        case (true, nil, _):
            descriptor.predicate = #Predicate { $0.isDownloaded }
        case (false, let kind?, _):
            descriptor.predicate = #Predicate { $0.kind == kind }
        case (false, nil, _):
            break
        }
        return ((try? fetch(descriptor)) ?? []).compactMap(value)
    }

    func saveItem(_ item: AnyItem, downloaded: Bool? = nil) {
        let id = item.id
        let key = id.storageKey
        guard let payload = JSON.encode(item) else { return }
        if let existing = try? fetch(FetchDescriptor<StoredItem>(predicate: #Predicate { $0.key == key })).first {
            existing.identifier = id.description
            existing.kind = id.kind.rawValue
            existing.name = item.name
            existing.searchText = item.searchText
            existing.payload = payload
            existing.updatedAt = .now
            if let downloaded {
                existing.isDownloaded = downloaded
                existing.downloadCompletedAt = downloaded ? (existing.downloadCompletedAt ?? .now) : nil
            }
        } else {
            insert(StoredItem(key: key, identifier: id.description, kind: id.kind.rawValue, connectionID: id.connectionID, libraryID: id.libraryID, primaryID: id.primaryID, groupingID: id.groupingID, name: item.name, searchText: item.searchText, payload: payload, isDownloaded: downloaded ?? false, downloadCompletedAt: downloaded == true ? .now : nil, updatedAt: .now))
        }
        commit()
    }

    func setItemDownloaded(_ id: ItemIdentifier, downloaded: Bool) {
        let key = id.storageKey
        guard let existing = try? fetch(FetchDescriptor<StoredItem>(predicate: #Predicate { $0.key == key })).first else { return }
        existing.isDownloaded = downloaded
        existing.downloadCompletedAt = downloaded ? .now : nil
        commit()
    }

    func deleteItem(_ id: ItemIdentifier) {
        let key = id.storageKey
        try? delete(model: StoredItem.self, where: #Predicate { $0.key == key })
        commit()
    }

    /// Downloaded items whose search text contains every token of the query.
    func searchDownloadedItems(tokens: [String]) -> [StoredItemValue] {
        let candidates = (try? fetch(FetchDescriptor<StoredItem>(predicate: #Predicate { $0.isDownloaded }))) ?? []
        return candidates
            .filter { item in tokens.allSatisfy { item.searchText.contains($0) } }
            .compactMap(value)
    }

    // MARK: Assets & chapters

    func assets(for id: ItemIdentifier? = nil) -> [DownloadAsset] {
        var descriptor = FetchDescriptor<StoredAsset>(sortBy: [SortDescriptor(\.index)])
        if let key = id?.storageKey {
            descriptor.predicate = #Predicate { $0.itemKey == key }
        }
        return ((try? fetch(descriptor)) ?? []).compactMap { stored in
            guard let itemID = ItemIdentifier(stored.identifier), let kind = AssetKind(rawValue: stored.kind) else { return nil }
            return DownloadAsset(id: stored.id, itemID: itemID, kind: kind, relativePath: stored.relativePath, ino: stored.ino, index: stored.index, offset: stored.offset, duration: stored.duration, mimeType: stored.mimeType, fileExtension: stored.fileExtension, imageSize: stored.imageSize.flatMap(ImageSize.init(rawValue:)), isDownloaded: stored.isDownloaded, taskIdentifier: stored.taskIdentifier, weight: stored.weight, failureCount: stored.failureCount, byteCount: stored.byteCount)
        }
    }

    func upsertAssets(_ assets: [DownloadAsset]) {
        for asset in assets {
            let id = asset.id
            if let existing = try? fetch(FetchDescriptor<StoredAsset>(predicate: #Predicate { $0.id == id })).first {
                existing.relativePath = asset.relativePath
                existing.isDownloaded = asset.isDownloaded
                existing.taskIdentifier = asset.taskIdentifier
                existing.failureCount = asset.failureCount
                existing.byteCount = asset.byteCount
                existing.weight = asset.weight
            } else {
                insert(StoredAsset(id: asset.id, itemKey: asset.itemID.storageKey, identifier: asset.itemID.description, connectionID: asset.itemID.connectionID, kind: asset.kind.rawValue, relativePath: asset.relativePath, ino: asset.ino, index: asset.index, offset: asset.offset, duration: asset.duration, mimeType: asset.mimeType, fileExtension: asset.fileExtension, imageSize: asset.imageSize?.rawValue, isDownloaded: asset.isDownloaded, taskIdentifier: asset.taskIdentifier, weight: asset.weight, failureCount: asset.failureCount, byteCount: asset.byteCount))
            }
        }
        commit()
    }

    func deleteAsset(id: String) {
        try? delete(model: StoredAsset.self, where: #Predicate { $0.id == id })
        commit()
    }

    func deleteAssets(for id: ItemIdentifier) {
        let key = id.storageKey
        try? delete(model: StoredAsset.self, where: #Predicate { $0.itemKey == key })
        try? delete(model: StoredChapter.self, where: #Predicate { $0.itemKey == key })
        commit()
    }

    func chapters(for id: ItemIdentifier) -> [Chapter] {
        let key = id.storageKey
        let stored = (try? fetch(FetchDescriptor<StoredChapter>(predicate: #Predicate { $0.itemKey == key }, sortBy: [SortDescriptor(\.start)]))) ?? []
        return stored.map { Chapter(id: $0.chapterID, start: $0.start, end: $0.end, title: $0.title) }
    }

    func replaceChapters(_ chapters: [Chapter], for id: ItemIdentifier) {
        let key = id.storageKey
        try? delete(model: StoredChapter.self, where: #Predicate { $0.itemKey == key })
        for chapter in chapters {
            insert(StoredChapter(key: "\(key)#\(chapter.id)#\(chapter.start)", itemKey: key, chapterID: chapter.id, start: chapter.start, end: chapter.end, title: chapter.title))
        }
        commit()
    }

    // MARK: Local sessions

    func localSessions() -> [LocalSessionRecord] {
        let stored = (try? fetch(FetchDescriptor<StoredLocalSession>(sortBy: [SortDescriptor(\.startedAt)]))) ?? []
        return stored.compactMap { stored in
            guard let itemID = ItemIdentifier(stored.identifier) else { return nil }
            return LocalSessionRecord(id: stored.id, itemID: itemID, startTime: stored.startTime, currentTime: stored.currentTime, duration: stored.duration, timeListened: stored.timeListened, startedAt: stored.startedAt, updatedAt: stored.updatedAt, isClosed: stored.isClosed)
        }
    }

    func upsertLocalSession(_ session: LocalSessionRecord) {
        let id = session.id
        if let existing = try? fetch(FetchDescriptor<StoredLocalSession>(predicate: #Predicate { $0.id == id })).first {
            existing.currentTime = session.currentTime
            existing.duration = session.duration
            existing.timeListened = session.timeListened
            existing.updatedAt = session.updatedAt
            existing.isClosed = session.isClosed
        } else {
            insert(StoredLocalSession(id: session.id, identifier: session.itemID.description, connectionID: session.itemID.connectionID, startTime: session.startTime, currentTime: session.currentTime, duration: session.duration, timeListened: session.timeListened, startedAt: session.startedAt, updatedAt: session.updatedAt, isClosed: session.isClosed))
        }
        commit()
    }

    func deleteLocalSession(id: String) {
        try? delete(model: StoredLocalSession.self, where: #Predicate { $0.id == id })
        commit()
    }

    // MARK: Settings

    func allSettings() -> [String: Data] {
        let stored = (try? fetch(FetchDescriptor<StoredSetting>())) ?? []
        return Dictionary(stored.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    func setSetting(_ value: Data?, for key: String) {
        if let existing = try? fetch(FetchDescriptor<StoredSetting>(predicate: #Predicate { $0.key == key })).first {
            if let value {
                existing.value = value
                existing.updatedAt = .now
            } else {
                delete(existing)
            }
        } else if let value {
            insert(StoredSetting(key: key, value: value, updatedAt: .now))
        }
        commit()
    }

    func deleteSettings(withPrefix prefix: String) {
        let stored = (try? fetch(FetchDescriptor<StoredSetting>())) ?? []
        for setting in stored where setting.key.hasPrefix(prefix) {
            delete(setting)
        }
        commit()
    }

    // MARK: Known servers

    func knownServers() -> [KnownServer] {
        let stored = (try? fetch(FetchDescriptor<StoredKnownServer>(sortBy: [SortDescriptor(\.lastUsed, order: .reverse)]))) ?? []
        return stored.compactMap { stored in
            URL(string: stored.host).map { KnownServer(host: $0, username: stored.username) }
        }
    }

    func addKnownServer(_ server: KnownServer) {
        let key = server.id
        if let existing = try? fetch(FetchDescriptor<StoredKnownServer>(predicate: #Predicate { $0.key == key })).first {
            existing.lastUsed = .now
        } else {
            insert(StoredKnownServer(key: key, host: server.host.absoluteString, username: server.username, lastUsed: .now))
        }
        commit()
    }

    // MARK: Auto downloads

    func autoDownloadRules() -> [AutoDownloadRuleRecord] {
        let stored = (try? fetch(FetchDescriptor<StoredAutoDownloadRule>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        return stored.compactMap { stored in
            guard let rule = JSON.decode(AutoDownloadRule.self, from: stored.rule) else { return nil }
            if stored.key == AutoDownloadRuleKey.listenNow {
                return AutoDownloadRuleRecord(grouping: nil, rule: rule)
            }
            guard let grouping = ItemIdentifier(stored.identifier) else { return nil }
            return AutoDownloadRuleRecord(grouping: grouping, rule: rule)
        }
    }

    func setAutoDownloadRule(_ record: AutoDownloadRuleRecord) {
        let key = record.key
        try? delete(model: StoredAutoDownloadRule.self, where: #Predicate { $0.key == key })
        if record.rule != .disabled, let data = JSON.encode(record.rule) {
            insert(StoredAutoDownloadRule(key: key, identifier: record.grouping?.description ?? "", connectionID: record.grouping?.connectionID ?? "", rule: data, createdAt: .now))
        }
        commit()
    }

    func autoDownloadedItems() -> [AutoDownloadedItemRecord] {
        let stored = (try? fetch(FetchDescriptor<StoredAutoDownloadedItem>())) ?? []
        return stored.compactMap { stored in
            ItemIdentifier(stored.identifier).map { AutoDownloadedItemRecord(ruleKey: stored.ruleKey, itemID: $0, downloadedAt: stored.downloadedAt) }
        }
    }

    func addAutoDownloadedItem(_ itemID: ItemIdentifier, ruleKey: String) {
        let key = "\(ruleKey)|\(itemID.storageKey)"
        guard ((try? fetchCount(FetchDescriptor<StoredAutoDownloadedItem>(predicate: #Predicate { $0.key == key }))) ?? 0) == 0 else { return }
        insert(StoredAutoDownloadedItem(key: key, ruleKey: ruleKey, itemKey: itemID.storageKey, identifier: itemID.description, connectionID: itemID.connectionID, downloadedAt: .now))
        commit()
    }

    func removeAutoDownloadedItem(_ itemID: ItemIdentifier, ruleKey: String?) {
        let itemKey = itemID.storageKey
        if let ruleKey {
            let key = "\(ruleKey)|\(itemKey)"
            try? delete(model: StoredAutoDownloadedItem.self, where: #Predicate { $0.key == key })
        } else {
            try? delete(model: StoredAutoDownloadedItem.self, where: #Predicate { $0.itemKey == itemKey })
        }
        commit()
    }

    func removeAutoDownloadedItems(ruleKey: String) {
        try? delete(model: StoredAutoDownloadedItem.self, where: #Predicate { $0.ruleKey == ruleKey })
        commit()
    }

    // MARK: Connection removal

    func deleteAll(connectionID: ConnectionID) {
        try? delete(model: StoredItem.self, where: #Predicate { $0.connectionID == connectionID })
        try? delete(model: StoredAsset.self, where: #Predicate { $0.connectionID == connectionID })
        try? delete(model: StoredBookmark.self, where: #Predicate { $0.connectionID == connectionID })
        try? delete(model: StoredProgress.self, where: #Predicate { $0.connectionID == connectionID })
        try? delete(model: StoredLocalSession.self, where: #Predicate { $0.connectionID == connectionID })
        try? delete(model: StoredAutoDownloadRule.self, where: #Predicate { $0.connectionID == connectionID })
        try? delete(model: StoredAutoDownloadedItem.self, where: #Predicate { $0.connectionID == connectionID })
        // Chapters and settings are keyed by item key, which starts with the connection id.
        let prefix = "\(connectionID)::"
        let chapters = (try? fetch(FetchDescriptor<StoredChapter>())) ?? []
        for chapter in chapters where chapter.itemKey.hasPrefix(prefix) {
            delete(chapter)
        }
        let settings = (try? fetch(FetchDescriptor<StoredSetting>())) ?? []
        for setting in settings where setting.key.hasPrefix(prefix) {
            delete(setting)
        }
        commit()
    }
}
