import Foundation
import HearthModel

/// Pure reconcile logic for bookmarks (spec §4.4). Identity = (item, whole-second time).
///
/// | Local status | Remote exists | Action |
/// |---|---|---|
/// | deleted | yes | DELETE remote, then delete locally |
/// | deleted | no | delete locally |
/// | pendingCreate / pendingUpdate | yes, same note | mark synced |
/// | pendingCreate / pendingUpdate | yes, other note | PATCH |
/// | pendingCreate / pendingUpdate | no | POST |
/// | synced | yes | take remote |
/// | synced | no | delete locally (deleted elsewhere) |
/// | – (remote only) | yes | insert locally |
///
/// Items whose server entries couldn't be mapped (`unresolvedItemIDs`) are left alone when no remote copy is known:
/// the server may well have it.
enum BookmarkReconciler {
    struct Plan: Sendable, Equatable {
        var create: [Bookmark] = []
        var update: [Bookmark] = []
        var deleteRemote: [Bookmark] = []
        var upsertLocal: [BookmarkRecord] = []
        var deleteLocal: [String] = []
    }

    static func plan(local: [BookmarkRecord], remote: [Bookmark], unresolvedItemIDs: Set<String> = []) -> Plan {
        var plan = Plan()
        var remoteByKey = [String: Bookmark]()
        for bookmark in remote {
            remoteByKey[BookmarkRecord.key(bookmark.itemID, time: bookmark.time)] = bookmark
        }
        var seen = Set<String>()

        for record in local.sorted(by: { $0.key < $1.key }) {
            let key = record.key
            seen.insert(key)
            let remote = remoteByKey[key]
            if remote == nil, unresolvedItemIDs.contains(record.bookmark.itemID.apiItemID) {
                continue
            }
            switch record.status {
            case .deleted:
                if remote != nil {
                    plan.deleteRemote.append(record.bookmark)
                } else {
                    plan.deleteLocal.append(key)
                }
            case .pendingCreate, .pendingUpdate:
                if let remote {
                    if remote.note == record.bookmark.note {
                        plan.upsertLocal.append(BookmarkRecord(bookmark: remote.withItemID(record.bookmark.itemID), status: .synced))
                    } else {
                        plan.update.append(record.bookmark)
                    }
                } else {
                    plan.create.append(record.bookmark)
                }
            case .synced:
                if let remote {
                    if remote.note != record.bookmark.note || remote.created != record.bookmark.created {
                        plan.upsertLocal.append(BookmarkRecord(bookmark: remote.withItemID(record.bookmark.itemID), status: .synced))
                    }
                } else {
                    plan.deleteLocal.append(key)
                }
            }
        }

        for (key, bookmark) in remoteByKey.sorted(by: { $0.key < $1.key }) where !seen.contains(key) {
            plan.upsertLocal.append(BookmarkRecord(bookmark: bookmark, status: .synced))
        }
        return plan
    }
}

extension Bookmark {
    /// Keeps the locally known identifier (with kind and library) while taking the server's values.
    func withItemID(_ itemID: ItemIdentifier) -> Bookmark {
        Bookmark(itemID: itemID, time: time, note: note, created: created)
    }
}
