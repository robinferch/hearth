import Foundation
import HearthModel

/// Pure reconcile logic between local progress records and the server's `mediaProgress` (spec §4.3).
///
/// | Case | Action |
/// |---|---|
/// | local only & dirty | push |
/// | local only & synced (or tombstone) | delete locally |
/// | remote only | insert locally |
/// | both, local tombstone | DELETE remote |
/// | both, remote lastUpdate missing or older than local | push local |
/// | both, equal currentTime (and finished state) | nothing (mark synced, adopt server id) |
/// | otherwise | remote wins |
///
/// Server duplicates (several progress objects for one item): the newest wins, the others are deleted remotely.
/// Items are matched on `storageKey` (connection + server ids) since server payloads have no library id.
enum ProgressReconciler {
    struct Tombstone: Sendable, Equatable {
        var progressID: String
        var itemID: ItemIdentifier
    }

    struct Plan: Sendable, Equatable {
        /// Entities to send in one batch update; mark synced on success.
        var push: [ProgressEntity] = []
        /// Server progress to delete because the local record is a tombstone. Delete locally on success.
        var deleteRemoteTombstones: [Tombstone] = []
        /// Server progress ids of duplicates.
        var deleteRemoteDuplicates: [String] = []
        /// Records to write locally (already synced).
        var upsertLocal: [ProgressRecord] = []
        /// Local records to remove.
        var deleteLocal: [ItemIdentifier] = []
    }

    /// Tolerance when comparing playback positions.
    static let timeTolerance: TimeInterval = 1

    static func plan(local: [ProgressRecord], remote: [ProgressEntity]) -> Plan {
        var plan = Plan()

        // Collapse server duplicates.
        var remoteByKey = [String: ProgressEntity]()
        for entity in remote.sorted(by: { $0.id < $1.id }) {
            let key = entity.itemID.storageKey
            if let existing = remoteByKey[key] {
                if entity.lastUpdate > existing.lastUpdate {
                    plan.deleteRemoteDuplicates.append(existing.id)
                    remoteByKey[key] = entity
                } else {
                    plan.deleteRemoteDuplicates.append(entity.id)
                }
            } else {
                remoteByKey[key] = entity
            }
        }

        var localByKey = [String: ProgressRecord]()
        for record in local {
            let key = record.entity.itemID.storageKey
            if let existing = localByKey[key], existing.entity.lastUpdate >= record.entity.lastUpdate {
                continue
            }
            localByKey[key] = record
        }

        for (key, record) in localByKey.sorted(by: { $0.key < $1.key }) {
            guard var remote = remoteByKey[key] else {
                switch record.status {
                case .dirty:
                    plan.push.append(record.entity)
                case .synced, .tombstone:
                    plan.deleteLocal.append(record.entity.itemID)
                }
                continue
            }
            remote.itemID = preferredIdentifier(local: record.entity.itemID, remote: remote.itemID)

            if record.status == .tombstone {
                plan.deleteRemoteTombstones.append(Tombstone(progressID: remote.id, itemID: record.entity.itemID))
                continue
            }

            if remote.lastUpdate < record.entity.lastUpdate {
                var entity = record.entity
                entity.id = remote.id
                plan.push.append(entity)
            } else if abs(remote.currentTime - record.entity.currentTime) < timeTolerance, remote.isFinished == record.entity.isFinished {
                if record.status != .synced || !record.hasServerID || record.entity.id != remote.id || record.entity.hideFromContinueListening != remote.hideFromContinueListening {
                    var entity = record.entity
                    entity.id = remote.id
                    entity.hideFromContinueListening = remote.hideFromContinueListening
                    plan.upsertLocal.append(ProgressRecord(entity: entity, status: .synced, hasServerID: true))
                }
            } else {
                plan.upsertLocal.append(ProgressRecord(entity: remote, status: .synced, hasServerID: true))
            }
        }

        for (key, remote) in remoteByKey.sorted(by: { $0.key < $1.key }) where localByKey[key] == nil {
            plan.upsertLocal.append(ProgressRecord(entity: remote, status: .synced, hasServerID: true))
        }

        return plan
    }

    /// Keeps the local identifier when the server's lacks a library id.
    static func preferredIdentifier(local: ItemIdentifier, remote: ItemIdentifier) -> ItemIdentifier {
        remote.libraryID.isEmpty ? local : remote
    }

    /// Whether a live (socket) update should replace the local record.
    static func shouldApplyLive(_ remote: ProgressEntity, over local: ProgressRecord?) -> Bool {
        guard let local else { return true }
        switch local.status {
        case .tombstone:
            return false
        case .dirty:
            return remote.lastUpdate > local.entity.lastUpdate
        case .synced:
            return remote.lastUpdate >= local.entity.lastUpdate
        }
    }
}
