import Foundation
import HearthAPI
import HearthModel
import Observation
import os
import SwiftData

/// Audiobook bookmarks: local-first with pending statuses, synced with the server.
@MainActor
@Observable
public final class BookmarkStore {
    /// Visible bookmarks per item (`storageKey`), sorted by time.
    private var byItem: [String: [Bookmark]] = [:]

    @ObservationIgnored private var records: [String: BookmarkRecord] = [:]
    /// Monotonic change counter and its value at each record's last change (see `ProgressStore.changeMark`).
    @ObservationIgnored private var changeCounter: UInt64 = 0
    @ObservationIgnored private var changeStamps: [String: UInt64] = [:]
    @ObservationIgnored let environment: DataEnvironment
    @ObservationIgnored weak var hearth: HearthData?
    @ObservationIgnored private let logger = Logger(category: "BookmarkStore")

    init(environment: DataEnvironment) {
        self.environment = environment
        let context = ModelContext(environment.container)
        for record in context.bookmarkRecords() {
            records[record.key] = record
        }
        rebuild(Set(records.values.map(\.bookmark.itemID.storageKey)))
    }

    // MARK: Reading

    public func bookmarks(for id: ItemIdentifier) -> [Bookmark] {
        byItem[id.storageKey] ?? []
    }

    /// Item ids (audiobooks) with at least one bookmark, with counts.
    ///
    /// Bookmarks created on other devices arrive without a library id; they are listed for every library of their
    /// connection until the item is resolved.
    public func bookmarkedItems(in library: LibraryIdentifier) -> [(itemID: ItemIdentifier, count: Int)] {
        byItem.values
            .compactMap { bookmarks -> (itemID: ItemIdentifier, count: Int)? in
                guard let itemID = bookmarks.first?.itemID, itemID.connectionID == library.connectionID,
                      itemID.libraryID == library.libraryID || itemID.libraryID.isEmpty
                else { return nil }
                return (itemID: itemID, count: bookmarks.count)
            }
            .sorted { ($0.count, $0.itemID.description) > ($1.count, $1.itemID.description) }
    }

    private func rebuild(_ keys: Set<String>) {
        guard !keys.isEmpty else { return }
        var grouped = [String: [Bookmark]]()
        for record in records.values where record.status != .deleted {
            let key = record.bookmark.itemID.storageKey
            if keys.contains(key) {
                grouped[key, default: []].append(record.bookmark)
            }
        }
        for key in keys {
            let bookmarks = grouped[key]?.sorted { $0.time < $1.time }
            if byItem[key] != bookmarks {
                byItem[key] = bookmarks
            }
        }
    }

    private func commit(_ changed: [BookmarkRecord], removed: [String] = []) async {
        var affected = Set<String>()
        changeCounter &+= 1
        for key in changed.map(\.key) + removed {
            changeStamps[key] = changeCounter
        }
        for record in changed {
            records[record.key] = record
            affected.insert(record.bookmark.itemID.storageKey)
        }
        for key in removed {
            if let record = records.removeValue(forKey: key) {
                affected.insert(record.bookmark.itemID.storageKey)
            }
        }
        rebuild(affected)
        await environment.store.perform { context in
            if !changed.isEmpty {
                context.upsertBookmarks(changed)
            }
            if !removed.isEmpty {
                context.deleteBookmarks(keys: removed)
            }
        }
    }

    // MARK: Mutations

    @discardableResult
    public func create(_ id: ItemIdentifier, time: TimeInterval, note: String?) async throws -> Bookmark {
        let seconds = Int(max(0, time).rounded(.down))
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = trimmed.isEmpty ? Date.now.formatted(date: .abbreviated, time: .shortened) : trimmed
        let key = BookmarkRecord.key(id, time: seconds)
        let existing = records[key]
        let status: BookmarkSyncStatus = (existing == nil || existing?.status == .pendingCreate) ? .pendingCreate : .pendingUpdate
        let record = BookmarkRecord(bookmark: Bookmark(itemID: id, time: seconds, note: text, created: existing?.bookmark.created ?? .now), status: status)
        await commit([record])
        await push(record)
        return records[key]?.bookmark ?? record.bookmark
    }

    public func update(_ bookmark: Bookmark, note: String) async throws {
        let key = BookmarkRecord.key(bookmark.itemID, time: bookmark.time)
        var record = records[key] ?? BookmarkRecord(bookmark: bookmark, status: .pendingUpdate)
        record.bookmark.note = note
        if record.status != .pendingCreate {
            record.status = .pendingUpdate
        }
        await commit([record])
        await push(record)
    }

    public func delete(_ bookmark: Bookmark) async throws {
        let key = BookmarkRecord.key(bookmark.itemID, time: bookmark.time)
        guard var record = records[key] else { return }
        record.status = .deleted
        await commit([record])
        await push(record)
    }

    /// Sends one record to the server if its connection is available.
    private func push(_ record: BookmarkRecord) async {
        let id = record.bookmark.itemID
        guard let hearth, hearth.connections.isAvailable(id.connectionID), let client = try? hearth.connections.client(for: id.connectionID) else { return }
        await perform(record, client: client)
    }

    private func perform(_ record: BookmarkRecord, client: any AudiobookshelfClient) async {
        let bookmark = record.bookmark
        do {
            switch record.status {
            case .synced:
                return
            case .pendingCreate:
                let created = try await client.createBookmark(bookmark.itemID, time: bookmark.time, note: bookmark.note)
                await markSynced(record, created: created.created)
            case .pendingUpdate:
                do {
                    try await client.updateBookmark(bookmark.itemID, time: bookmark.time, note: bookmark.note)
                    await markSynced(record, created: nil)
                } catch APIError.notFound {
                    let created = try await client.createBookmark(bookmark.itemID, time: bookmark.time, note: bookmark.note)
                    await markSynced(record, created: created.created)
                }
            case .deleted:
                do {
                    try await client.deleteBookmark(bookmark.itemID, time: bookmark.time)
                } catch APIError.notFound {
                    // Already gone.
                }
                if records[record.key]?.status == .deleted {
                    await commit([], removed: [record.key])
                }
            }
        } catch {
            logger.error("Bookmark sync failed, will retry: \(String(describing: error), privacy: .public)")
        }
    }

    private func markSynced(_ pushed: BookmarkRecord, created: Date?) async {
        guard var current = records[pushed.key], current.status == pushed.status, current.bookmark.note == pushed.bookmark.note else { return }
        current.status = .synced
        if let created {
            current.bookmark.created = created
        }
        await commit([current])
    }

    // MARK: Sync

    /// Current change counter; records changed after it are skipped by `reconcile(…changedAfter:)`.
    var changeMark: UInt64 { changeCounter }

    public func sync() async {
        guard let hearth, !hearth.connections.isOffline else { return }
        for connection in hearth.connections.connections where hearth.connections.isAvailable(connection.id) {
            guard let client = try? hearth.connections.client(for: connection.id) else { continue }
            let mark = changeMark
            do {
                let response = try await client.authorize()
                await reconcile(connection: connection.id, remote: response.bookmarks, client: client, unresolvedItemIDs: response.unresolvedItemIDs, changedAfter: mark)
            } catch {
                logger.error("Bookmark sync of \(connection.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// - Parameters:
    ///   - unresolvedItemIDs: items the server has entries for that couldn't be mapped (never deleted locally).
    ///   - changedAfter: `changeMark` taken before the server state was fetched; records changed since are left
    ///     for the next reconcile.
    func reconcile(connection: ConnectionID, remote: [Bookmark], client: any AudiobookshelfClient, unresolvedItemIDs: Set<String> = [], changedAfter mark: UInt64? = nil) async {
        let recent: Set<String> = mark.map { mark in Set(changeStamps.compactMap { $0.value > mark ? $0.key : nil }) } ?? []
        let local = records.values.filter { $0.bookmark.itemID.connectionID == connection && !recent.contains($0.key) }
        // Remote bookmarks don't know our library id; resolve it from local data where possible.
        let remote = remote.map { bookmark in
            if let known = records[BookmarkRecord.key(bookmark.itemID, time: bookmark.time)] {
                return bookmark.withItemID(known.bookmark.itemID)
            }
            return bookmark
        }.filter { !recent.contains(BookmarkRecord.key($0.itemID, time: $0.time)) }
        let plan = BookmarkReconciler.plan(local: Array(local), remote: remote, unresolvedItemIDs: unresolvedItemIDs)
        await commit(plan.upsertLocal, removed: plan.deleteLocal)

        for bookmark in plan.create {
            await perform(BookmarkRecord(bookmark: bookmark, status: .pendingCreate), client: client)
        }
        for bookmark in plan.update {
            await perform(BookmarkRecord(bookmark: bookmark, status: .pendingUpdate), client: client)
        }
        for bookmark in plan.deleteRemote {
            await perform(BookmarkRecord(bookmark: bookmark, status: .deleted), client: client)
        }
    }

    func forget(connection: ConnectionID) {
        let keys = records.filter { $0.value.bookmark.itemID.connectionID == connection }.map(\.key)
        var affected = Set<String>()
        for key in keys {
            if let record = records.removeValue(forKey: key) {
                affected.insert(record.bookmark.itemID.storageKey)
            }
        }
        rebuild(affected)
    }
}
