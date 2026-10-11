import Foundation
import HearthAPI
import HearthModel
import Observation
import os
import SwiftData

/// Per-item observable cell so views only re-render when *their* item's progress changes.
@MainActor
@Observable
final class ProgressCell {
    var value: ProgressEntity?

    init(value: ProgressEntity?) {
        self.value = value
    }
}

/// Listening progress of all connections: local-first, reconciled with the server.
///
/// Records are keyed by `ItemIdentifier.storageKey` (connection + server ids) because the server's progress
/// payloads don't carry library ids.
@MainActor
@Observable
public final class ProgressStore {
    /// Whether a reconcile is running.
    public internal(set) var isSyncing = false

    /// Bumped on every change; read by aggregate queries so they are observed as a whole.
    private var revision = 0

    @ObservationIgnored private var records: [String: ProgressRecord] = [:]
    @ObservationIgnored private var cells: [String: ProgressCell] = [:]
    /// Monotonic change counter and the value it had at each key's last change. A reconcile skips keys changed
    /// while its `api/authorize` request was in flight: the response may predate them.
    @ObservationIgnored private var changeCounter: UInt64 = 0
    @ObservationIgnored private var changeStamps: [String: UInt64] = [:]
    @ObservationIgnored let environment: DataEnvironment
    @ObservationIgnored weak var hearth: HearthData?
    @ObservationIgnored private let logger = Logger(category: "ProgressStore")

    init(environment: DataEnvironment) {
        self.environment = environment
        let context = ModelContext(environment.container)
        for record in context.progressRecords() {
            records[record.entity.itemID.storageKey] = record
        }
    }

    // MARK: Reading

    /// Observable lookup (UI re-renders when this item's progress changes).
    public func progress(for id: ItemIdentifier) -> ProgressEntity? {
        cell(for: id).value
    }

    /// Items in progress across all connections, most recent first.
    public func inProgress() -> [ProgressEntity] {
        _ = revision
        return records.values
            .filter { $0.status != .tombstone && $0.entity.isInProgress && !$0.entity.hideFromContinueListening }
            .map(\.entity)
            .sorted { $0.lastUpdate > $1.lastUpdate }
    }

    /// All visible progress entities (finished included).
    public func all() -> [ProgressEntity] {
        _ = revision
        return records.values.filter { $0.status != .tombstone }.map(\.entity)
    }

    public func isFinished(_ id: ItemIdentifier) -> Bool {
        progress(for: id)?.isFinished ?? false
    }

    /// Non-observing lookup for background logic.
    func peek(_ id: ItemIdentifier) -> ProgressEntity? {
        Self.visible(records[id.storageKey])
    }

    func record(for id: ItemIdentifier) -> ProgressRecord? {
        records[id.storageKey]
    }

    private func cell(for id: ItemIdentifier) -> ProgressCell {
        let key = id.storageKey
        if let cell = cells[key] {
            return cell
        }
        let cell = ProgressCell(value: Self.visible(records[key]))
        cells[key] = cell
        return cell
    }

    private static func visible(_ record: ProgressRecord?) -> ProgressEntity? {
        guard let record, record.status != .tombstone else { return nil }
        return record.entity
    }

    // MARK: Applying changes

    private func apply(_ changed: [ProgressRecord], removed: [ItemIdentifier] = []) {
        guard !changed.isEmpty || !removed.isEmpty else { return }
        var listenNowChanged = false
        changeCounter &+= 1
        for record in changed {
            let key = record.entity.itemID.storageKey
            changeStamps[key] = changeCounter
            listenNowChanged = listenNowChanged || Self.isListed(records[key]) != Self.isListed(record)
            records[key] = record
            if let cell = cells[key] {
                let visible = Self.visible(record)
                if cell.value != visible {
                    cell.value = visible
                }
            }
        }
        for id in removed {
            changeStamps[id.storageKey] = changeCounter
            listenNowChanged = listenNowChanged || Self.isListed(records[id.storageKey])
            records[id.storageKey] = nil
            cells[id.storageKey]?.value = nil
        }
        revision &+= 1
        if listenNowChanged {
            hearth?.listenNowChanged()
        }
    }

    /// Whether a record makes its item appear in Listen Now.
    private static func isListed(_ record: ProgressRecord?) -> Bool {
        guard let record, record.status != .tombstone else { return false }
        return record.entity.isInProgress && !record.entity.hideFromContinueListening
    }

    private func commit(_ changed: [ProgressRecord], removed: [ItemIdentifier] = []) async {
        apply(changed, removed: removed)
        await environment.store.perform { context in
            if !changed.isEmpty {
                context.upsertProgress(changed)
            }
            if !removed.isEmpty {
                context.deleteProgress(removed)
            }
        }
    }

    /// Mutable copy of the current record, or a fresh dirty one.
    private func editableRecord(for id: ItemIdentifier) -> ProgressRecord {
        if let record = records[id.storageKey], record.status != .tombstone {
            return record
        }
        var entity = ProgressEntity.empty(for: id)
        entity.startedAt = .now
        return ProgressRecord(entity: entity, status: .dirty, hasServerID: false)
    }

    // MARK: Local updates

    /// Called by the playback reporter. Marks the record dirty so the next sync pushes it.
    public func update(_ id: ItemIdentifier, currentTime: TimeInterval, duration: TimeInterval) async {
        var record = editableRecord(for: id)
        var entity = record.entity
        entity.currentTime = max(0, currentTime)
        if duration > 0 {
            entity.duration = duration
            entity.progress = min(1, max(0, currentTime / duration))
        }
        if entity.progress >= 1 {
            entity.finishedAt = entity.finishedAt ?? .now
        } else {
            entity.finishedAt = nil
        }
        entity.startedAt = entity.startedAt ?? .now
        entity.lastUpdate = .now
        entity.hideFromContinueListening = false
        record.entity = entity
        record.status = .dirty
        await commit([record])
    }

    /// Writes locally, then pushes in a batch update when the connection is available.
    public func setFinished(_ id: ItemIdentifier, finished: Bool) async throws {
        var record = editableRecord(for: id)
        var entity = record.entity
        let duration = entity.duration ?? hearth?.items.cachedPlayable(id)?.duration
        if finished {
            entity.progress = 1
            entity.duration = duration
            entity.currentTime = duration ?? entity.currentTime
            entity.finishedAt = .now
        } else {
            entity.progress = 0
            entity.currentTime = 0
            entity.finishedAt = nil
        }
        entity.startedAt = entity.startedAt ?? .now
        entity.lastUpdate = .now
        entity.hideFromContinueListening = false
        record.entity = entity
        record.status = .dirty
        await commit([record])
        await push([entity])
        hearth?.progressFinishedStateChanged(id, finished: finished)
    }

    /// Resets progress. Deletes the server copy; if that fails the record becomes a tombstone that is kept until
    /// the deletion succeeds during a later sync.
    public func reset(_ id: ItemIdentifier) async throws {
        guard var record = records[id.storageKey], record.status != .tombstone else { return }
        record.status = .tombstone
        await commit([record])
        hearth?.progressFinishedStateChanged(id, finished: false)

        guard let hearth, hearth.connections.isAvailable(id.connectionID), let client = try? hearth.connections.client(for: id.connectionID) else {
            return
        }
        guard record.hasServerID else {
            // The server may have a copy we don't know the id of; a reconcile resolves it.
            await sync(connection: id.connectionID)
            return
        }
        do {
            try await client.deleteProgress(id: record.entity.id)
            await removeTombstone(id)
        } catch APIError.notFound {
            await removeTombstone(id)
        } catch {
            logger.error("Deleting progress failed, keeping tombstone: \(String(describing: error), privacy: .public)")
        }
    }

    private func removeTombstone(_ id: ItemIdentifier) async {
        guard records[id.storageKey]?.status == .tombstone else { return }
        await commit([], removed: [id])
    }

    public func hideFromContinueListening(_ id: ItemIdentifier) async throws {
        guard var record = records[id.storageKey], record.status != .tombstone else { return }
        record.entity.hideFromContinueListening = true
        record.entity.lastUpdate = .now
        record.status = .dirty
        await commit([record])

        guard record.hasServerID, let hearth, hearth.connections.isAvailable(id.connectionID), let client = try? hearth.connections.client(for: id.connectionID) else {
            return
        }
        do {
            try await client.hideFromContinueListening(progressID: record.entity.id)
            if var current = records[id.storageKey], current.entity.lastUpdate == record.entity.lastUpdate {
                current.status = .synced
                await commit([current])
            }
        } catch {
            logger.error("Hiding from continue listening failed, will push later: \(String(describing: error), privacy: .public)")
        }
    }

    /// Pushes entities of available connections in one batch per connection; marks them synced on success.
    private func push(_ entities: [ProgressEntity]) async {
        guard let hearth else { return }
        let grouped = Dictionary(grouping: entities, by: \.itemID.connectionID)
        for (connectionID, entities) in grouped {
            guard hearth.connections.isAvailable(connectionID), let client = try? hearth.connections.client(for: connectionID) else { continue }
            do {
                try await client.batchUpdateProgress(entities)
                await markSynced(entities)
            } catch {
                logger.error("Pushing progress failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Pushes every dirty record of a connection (cheap alternative to a full reconcile).
    func pushPending(connection: ConnectionID) async {
        let dirty = records.values.filter { $0.status == .dirty && $0.entity.itemID.connectionID == connection }.map(\.entity)
        guard !dirty.isEmpty else { return }
        await push(dirty)
    }

    private func markSynced(_ pushed: [ProgressEntity]) async {
        var changed = [ProgressRecord]()
        for entity in pushed {
            guard var record = records[entity.itemID.storageKey], record.status == .dirty, record.entity.lastUpdate == entity.lastUpdate else { continue }
            record.status = .synced
            record.entity.id = entity.id
            changed.append(record)
        }
        await commit(changed)
    }

    // MARK: Sync

    /// Current change counter; pass to `reconcile(…changedAfter:)` to skip records changed after this point.
    var changeMark: UInt64 { changeCounter }

    /// Keys changed after `mark`.
    private func keysChanged(after mark: UInt64?) -> Set<String> {
        guard let mark else { return [] }
        return Set(changeStamps.compactMap { $0.value > mark ? $0.key : nil })
    }

    /// Full reconcile with the server(s).
    public func sync() async {
        guard let hearth, !hearth.connections.isOffline else { return }
        let ids = hearth.connections.connections.map(\.id).filter { hearth.connections.isAvailable($0) }
        isSyncing = true
        defer { isSyncing = false }
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await self.sync(connection: id) }
            }
        }
    }

    /// Reconciles progress *and* bookmarks of one connection (both come from `api/authorize`).
    public func sync(connection: ConnectionID) async {
        guard let hearth, hearth.connections.isAvailable(connection), let client = try? hearth.connections.client(for: connection) else { return }
        let progressMark = changeMark
        let bookmarkMark = hearth.bookmarks.changeMark
        do {
            let response = try await client.authorize()
            await reconcile(connection: connection, remote: response.progress, client: client, unresolvedItemIDs: response.unresolvedItemIDs, changedAfter: progressMark)
            await hearth.bookmarks.reconcile(connection: connection, remote: response.bookmarks, client: client, unresolvedItemIDs: response.unresolvedItemIDs, changedAfter: bookmarkMark)
        } catch APIError.unauthorized {
            hearth.connections.markUnauthorized(connection)
        } catch {
            logger.error("Sync of \(connection, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// - Parameters:
    ///   - unresolvedItemIDs: items the server has entries for that couldn't be mapped (never deleted locally).
    ///   - changedAfter: `changeMark` taken before the server state was fetched; records changed since are left
    ///     for the next reconcile.
    func reconcile(connection: ConnectionID, remote: [ProgressEntity], client: any AudiobookshelfClient, unresolvedItemIDs: Set<String> = [], changedAfter mark: UInt64? = nil) async {
        let recent = keysChanged(after: mark)
        let local = records.values.filter { $0.entity.itemID.connectionID == connection && !recent.contains($0.entity.itemID.storageKey) }
        let remote = remote.filter { !recent.contains($0.itemID.storageKey) }
        let plan = ProgressReconciler.plan(local: Array(local), remote: remote, unresolvedItemIDs: unresolvedItemIDs)
        await commit(plan.upsertLocal, removed: plan.deleteLocal)

        if !plan.push.isEmpty {
            do {
                try await client.batchUpdateProgress(plan.push)
                await markSynced(plan.push)
            } catch {
                logger.error("Batch progress update failed: \(String(describing: error), privacy: .public)")
            }
        }

        for tombstone in plan.deleteRemoteTombstones {
            do {
                try await client.deleteProgress(id: tombstone.progressID)
                await removeTombstone(tombstone.itemID)
            } catch APIError.notFound {
                await removeTombstone(tombstone.itemID)
            } catch {
                logger.error("Deleting tombstoned progress failed: \(String(describing: error), privacy: .public)")
            }
        }

        for progressID in plan.deleteRemoteDuplicates {
            do {
                try await client.deleteProgress(id: progressID)
            } catch {
                logger.error("Deleting duplicate progress failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Applies a live `user_item_progress_updated` event.
    func applyLive(_ entity: ProgressEntity) async {
        let existing = records[entity.itemID.storageKey]
        guard ProgressReconciler.shouldApplyLive(entity, over: existing) else { return }
        let wasFinished = existing?.entity.isFinished ?? false
        var entity = entity
        if let existing {
            entity.itemID = ProgressReconciler.preferredIdentifier(local: existing.entity.itemID, remote: entity.itemID)
        }
        await commit([ProgressRecord(entity: entity, status: .synced, hasServerID: true)])
        if wasFinished != entity.isFinished {
            hearth?.progressFinishedStateChanged(entity.itemID, finished: entity.isFinished)
        }
    }

    /// Drops cached records of a removed connection (the database rows are deleted separately).
    func forget(connection: ConnectionID) {
        let ids = records.values.map(\.entity.itemID).filter { $0.connectionID == connection }
        apply([], removed: ids)
    }
}
