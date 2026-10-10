import Foundation
@testable import HearthData
import HearthAPI
import HearthModel
import Testing

@Suite("Progress reconcile table (spec §4.3)")
struct ProgressReconcilerTests {
    let connection = "conn"
    var book: ItemIdentifier { Fixtures.bookID("b1", connection: connection) }

    @Test func localOnlyDirtyIsPushed() {
        let local = ProgressRecord(entity: Fixtures.progress(book, id: "local", currentTime: 10, lastUpdate: Fixtures.date(10)), status: .dirty, hasServerID: false)
        let plan = ProgressReconciler.plan(local: [local], remote: [])
        #expect(plan.push == [local.entity])
        #expect(plan.deleteLocal.isEmpty)
        #expect(plan.upsertLocal.isEmpty)
    }

    @Test func localOnlySyncedIsDeletedLocally() {
        let local = ProgressRecord(entity: Fixtures.progress(book, currentTime: 10, lastUpdate: Fixtures.date(10)), status: .synced, hasServerID: true)
        let plan = ProgressReconciler.plan(local: [local], remote: [])
        #expect(plan.push.isEmpty)
        #expect(plan.deleteLocal == [book])
    }

    @Test func localOnlyTombstoneIsDeletedLocally() {
        let local = ProgressRecord(entity: Fixtures.progress(book, currentTime: 10, lastUpdate: Fixtures.date(10)), status: .tombstone, hasServerID: true)
        let plan = ProgressReconciler.plan(local: [local], remote: [])
        #expect(plan.deleteLocal == [book])
        #expect(plan.deleteRemoteTombstones.isEmpty)
    }

    @Test func remoteOnlyIsInserted() {
        let remote = Fixtures.progress(book, id: "server", currentTime: 30, lastUpdate: Fixtures.date(30))
        let plan = ProgressReconciler.plan(local: [], remote: [remote])
        #expect(plan.upsertLocal == [ProgressRecord(entity: remote, status: .synced, hasServerID: true)])
    }

    @Test func tombstoneDeletesRemote() {
        let local = ProgressRecord(entity: Fixtures.progress(book, id: "server", currentTime: 10, lastUpdate: Fixtures.date(10)), status: .tombstone, hasServerID: true)
        let remote = Fixtures.progress(book, id: "server", currentTime: 50, lastUpdate: Fixtures.date(50))
        let plan = ProgressReconciler.plan(local: [local], remote: [remote])
        #expect(plan.deleteRemoteTombstones == [.init(progressID: "server", itemID: book)])
        #expect(plan.push.isEmpty)
        #expect(plan.upsertLocal.isEmpty)
    }

    @Test func newerLocalIsPushedWithServerID() {
        let local = ProgressRecord(entity: Fixtures.progress(book, id: "local", currentTime: 80, lastUpdate: Fixtures.date(100)), status: .dirty, hasServerID: false)
        let remote = Fixtures.progress(book, id: "server", currentTime: 20, lastUpdate: Fixtures.date(50))
        let plan = ProgressReconciler.plan(local: [local], remote: [remote])
        #expect(plan.push.count == 1)
        #expect(plan.push.first?.id == "server")
        #expect(plan.push.first?.currentTime == 80)
    }

    @Test func missingRemoteLastUpdateCountsAsOlder() {
        let local = ProgressRecord(entity: Fixtures.progress(book, currentTime: 80, lastUpdate: Fixtures.date(100)), status: .synced, hasServerID: true)
        let remote = Fixtures.progress(book, id: "server", currentTime: 20, lastUpdate: .distantPast)
        let plan = ProgressReconciler.plan(local: [local], remote: [remote])
        #expect(plan.push.map(\.currentTime) == [80])
    }

    @Test func equalCurrentTimeDoesNothingWhenSynced() {
        let local = ProgressRecord(entity: Fixtures.progress(book, id: "server", currentTime: 40, lastUpdate: Fixtures.date(50)), status: .synced, hasServerID: true)
        let remote = Fixtures.progress(book, id: "server", currentTime: 40.4, lastUpdate: Fixtures.date(60))
        let plan = ProgressReconciler.plan(local: [local], remote: [remote])
        #expect(plan == ProgressReconciler.Plan())
    }

    @Test func equalCurrentTimeMarksDirtyRecordSynced() {
        let local = ProgressRecord(entity: Fixtures.progress(book, id: "local", currentTime: 40, lastUpdate: Fixtures.date(50)), status: .dirty, hasServerID: false)
        let remote = Fixtures.progress(book, id: "server", currentTime: 40, lastUpdate: Fixtures.date(60))
        let plan = ProgressReconciler.plan(local: [local], remote: [remote])
        #expect(plan.push.isEmpty)
        #expect(plan.upsertLocal.count == 1)
        #expect(plan.upsertLocal.first?.status == .synced)
        #expect(plan.upsertLocal.first?.entity.id == "server")
        #expect(plan.upsertLocal.first?.hasServerID == true)
    }

    @Test func otherwiseRemoteWins() {
        let local = ProgressRecord(entity: Fixtures.progress(book, id: "server", currentTime: 10, lastUpdate: Fixtures.date(10)), status: .dirty, hasServerID: true)
        let remote = Fixtures.progress(book, id: "server", currentTime: 70, lastUpdate: Fixtures.date(90))
        let plan = ProgressReconciler.plan(local: [local], remote: [remote])
        #expect(plan.push.isEmpty)
        #expect(plan.upsertLocal == [ProgressRecord(entity: remote, status: .synced, hasServerID: true)])
    }

    @Test func serverDuplicatesKeepNewest() {
        let old = Fixtures.progress(book, id: "old", currentTime: 10, lastUpdate: Fixtures.date(10))
        let newest = Fixtures.progress(book, id: "new", currentTime: 90, lastUpdate: Fixtures.date(90))
        let middle = Fixtures.progress(book, id: "mid", currentTime: 50, lastUpdate: Fixtures.date(50))
        let plan = ProgressReconciler.plan(local: [], remote: [old, newest, middle])
        #expect(Set(plan.deleteRemoteDuplicates) == ["old", "mid"])
        #expect(plan.upsertLocal.map(\.entity.id) == ["new"])
    }

    @Test func remoteWithoutLibraryKeepsLocalIdentifier() {
        let local = ProgressRecord(entity: Fixtures.progress(book, id: "server", currentTime: 10, lastUpdate: Fixtures.date(10)), status: .synced, hasServerID: true)
        let bare = ItemIdentifier(kind: .audiobook, connectionID: connection, libraryID: "", primaryID: "b1")
        let remote = Fixtures.progress(bare, id: "server", currentTime: 70, lastUpdate: Fixtures.date(90))
        let plan = ProgressReconciler.plan(local: [local], remote: [remote])
        #expect(plan.upsertLocal.first?.entity.itemID.libraryID == "books")
    }

    @Test func liveUpdatesRespectLocalState() {
        let remote = Fixtures.progress(book, currentTime: 50, lastUpdate: Fixtures.date(50))
        #expect(ProgressReconciler.shouldApplyLive(remote, over: nil))
        let tombstone = ProgressRecord(entity: Fixtures.progress(book, currentTime: 0, lastUpdate: Fixtures.date(10)), status: .tombstone, hasServerID: true)
        #expect(!ProgressReconciler.shouldApplyLive(remote, over: tombstone))
        let newerDirty = ProgressRecord(entity: Fixtures.progress(book, currentTime: 60, lastUpdate: Fixtures.date(60)), status: .dirty, hasServerID: true)
        #expect(!ProgressReconciler.shouldApplyLive(remote, over: newerDirty))
        let olderSynced = ProgressRecord(entity: Fixtures.progress(book, currentTime: 20, lastUpdate: Fixtures.date(20)), status: .synced, hasServerID: true)
        #expect(ProgressReconciler.shouldApplyLive(remote, over: olderSynced))
    }
}
