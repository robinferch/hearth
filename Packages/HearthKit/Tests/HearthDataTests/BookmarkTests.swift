import Foundation
@testable import HearthData
import HearthAPI
import HearthModel
import Testing

@Suite("Bookmark sync (spec §4.4)")
struct BookmarkReconcilerTests {
    let book = Fixtures.bookID("b1", connection: "conn")

    func bookmark(_ time: Int, _ note: String) -> Bookmark {
        Bookmark(itemID: book, time: time, note: note, created: Fixtures.date(Double(time)))
    }

    @Test func deletedWithRemoteIsDeletedRemotely() {
        let plan = BookmarkReconciler.plan(local: [BookmarkRecord(bookmark: bookmark(10, "a"), status: .deleted)], remote: [bookmark(10, "a")])
        #expect(plan.deleteRemote.map(\.time) == [10])
        #expect(plan.deleteLocal.isEmpty)
    }

    @Test func deletedWithoutRemoteIsDroppedLocally() {
        let local = BookmarkRecord(bookmark: bookmark(10, "a"), status: .deleted)
        let plan = BookmarkReconciler.plan(local: [local], remote: [])
        #expect(plan.deleteLocal == [local.key])
        #expect(plan.deleteRemote.isEmpty)
    }

    @Test func pendingCreateIsPosted() {
        let plan = BookmarkReconciler.plan(local: [BookmarkRecord(bookmark: bookmark(10, "a"), status: .pendingCreate)], remote: [])
        #expect(plan.create.map(\.note) == ["a"])
    }

    @Test func pendingUpdateIsPatchedOrCreated() {
        let existing = BookmarkReconciler.plan(local: [BookmarkRecord(bookmark: bookmark(10, "new"), status: .pendingUpdate)], remote: [bookmark(10, "old")])
        #expect(existing.update.map(\.note) == ["new"])
        let missing = BookmarkReconciler.plan(local: [BookmarkRecord(bookmark: bookmark(10, "new"), status: .pendingUpdate)], remote: [])
        #expect(missing.create.map(\.note) == ["new"])
    }

    @Test func pendingWithSameRemoteNoteBecomesSynced() {
        let plan = BookmarkReconciler.plan(local: [BookmarkRecord(bookmark: bookmark(10, "same"), status: .pendingCreate)], remote: [bookmark(10, "same")])
        #expect(plan.create.isEmpty)
        #expect(plan.update.isEmpty)
        #expect(plan.upsertLocal.map(\.status) == [.synced])
    }

    @Test func syncedTakesRemoteOrIsDeleted() {
        let changed = BookmarkReconciler.plan(local: [BookmarkRecord(bookmark: bookmark(10, "old"), status: .synced)], remote: [bookmark(10, "remote")])
        #expect(changed.upsertLocal.map(\.bookmark.note) == ["remote"])
        let gone = BookmarkReconciler.plan(local: [BookmarkRecord(bookmark: bookmark(10, "old"), status: .synced)], remote: [])
        #expect(gone.deleteLocal.count == 1)
    }

    @Test func unresolvedServerItemsAreLeftAlone() {
        let local = [
            BookmarkRecord(bookmark: bookmark(10, "synced"), status: .synced),
            BookmarkRecord(bookmark: bookmark(20, "deleted"), status: .deleted),
            BookmarkRecord(bookmark: bookmark(30, "new"), status: .pendingCreate),
        ]
        let plan = BookmarkReconciler.plan(local: local, remote: [], unresolvedItemIDs: [book.apiItemID])
        #expect(plan == BookmarkReconciler.Plan())
    }

    @Test func remoteOnlyIsInserted() {
        let plan = BookmarkReconciler.plan(local: [], remote: [bookmark(5, "x"), bookmark(7, "y")])
        #expect(plan.upsertLocal.map(\.bookmark.time) == [5, 7])
        #expect(plan.upsertLocal.allSatisfy { $0.status == .synced })
    }
}

@Suite("BookmarkStore")
@MainActor
struct BookmarkStoreTests {
    @Test func offlineCreateIsPushedOnSync() async throws {
        let client = MockClient(connection: Fixtures.connection())
        client.update { $0.failBookmarkWrites = true }
        let book = Fixtures.bookID("b1", connection: client.connection.id)
        let hearth = makeHearth([client])

        let created = try await hearth.bookmarks.create(book, time: 42.7, note: "Quote")
        #expect(created.time == 42)
        #expect(hearth.bookmarks.bookmarks(for: book).map(\.note) == ["Quote"])

        client.update { $0.failBookmarkWrites = false }
        await hearth.bookmarks.sync()
        #expect(client.read { $0.createdBookmarks.map(\.time) } == [42])

        // Synced now: a second sync with the server copy changes nothing.
        client.update { $0.authorizeBookmarks = $0.createdBookmarks }
        await hearth.bookmarks.sync()
        #expect(client.read { $0.createdBookmarks.count } == 1)
        #expect(hearth.bookmarks.bookmarks(for: book).count == 1)
    }

    @Test func deleteAndUpdateReachServer() async throws {
        let client = MockClient(connection: Fixtures.connection())
        let book = Fixtures.bookID("b1", connection: client.connection.id)
        let hearth = makeHearth([client])

        let bookmark = try await hearth.bookmarks.create(book, time: 10, note: "first")
        try await hearth.bookmarks.update(bookmark, note: "edited")
        #expect(client.read { $0.updatedBookmarks.map(\.note) } == ["edited"])

        try await hearth.bookmarks.delete(bookmark)
        #expect(client.read { $0.deletedBookmarks.map(\.time) } == [10])
        #expect(hearth.bookmarks.bookmarks(for: book).isEmpty)
    }

    @Test func bookmarkCreatedDuringSyncIsKept() async throws {
        let client = MockClient(connection: Fixtures.connection())
        client.update { $0.authorizeDelay = .milliseconds(300) }
        let book = Fixtures.bookID("b1", connection: client.connection.id)
        let hearth = makeHearth([client])

        // The authorize response predates the bookmark, which is pushed and synced while the request is in flight.
        let sync = Task { await hearth.progress.sync() }
        await client.waitForAuthorize()
        try await hearth.bookmarks.create(book, time: 5, note: "During sync")
        await sync.value
        #expect(hearth.bookmarks.bookmarks(for: book).map(\.note) == ["During sync"])
    }

    @Test func bookmarkedItemsCountsPerLibrary() async throws {
        let client = MockClient(connection: Fixtures.connection())
        let id = client.connection.id
        let hearth = makeHearth([client])
        try await hearth.bookmarks.create(Fixtures.bookID("a", connection: id), time: 1, note: "x")
        try await hearth.bookmarks.create(Fixtures.bookID("a", connection: id), time: 2, note: "y")
        try await hearth.bookmarks.create(Fixtures.bookID("b", connection: id), time: 1, note: "z")
        try await hearth.bookmarks.create(Fixtures.bookID("c", connection: id, library: "other"), time: 1, note: "z")

        let items = hearth.bookmarks.bookmarkedItems(in: LibraryIdentifier(connectionID: id, libraryID: "books"))
        #expect(items.map(\.itemID.primaryID) == ["a", "b"])
        #expect(items.map(\.count) == [2, 1])
    }
}
