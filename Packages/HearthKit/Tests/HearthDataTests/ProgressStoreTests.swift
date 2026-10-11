import Foundation
@testable import HearthData
import HearthAPI
import HearthModel
import Testing

@Suite("ProgressStore")
@MainActor
struct ProgressStoreTests {
    @Test func updateMarksRecordDirtyAndPersists() async {
        let client = MockClient(connection: Fixtures.connection())
        let hearth = makeHearth([client])
        let book = Fixtures.bookID("b1", connection: client.connection.id)

        await hearth.progress.update(book, currentTime: 30, duration: 120)

        let record = hearth.progress.record(for: book)
        #expect(record?.status == .dirty)
        #expect(record?.entity.progress == 0.25)
        #expect(hearth.progress.progress(for: book)?.currentTime == 30)

        // A fresh store over the same database sees the record.
        let reloaded = ProgressStore(environment: hearth.environment)
        #expect(reloaded.record(for: book)?.status == .dirty)
        #expect(reloaded.record(for: book)?.entity.currentTime == 30)
    }

    @Test func syncPushesDirtyAndInsertsRemote() async {
        let client = MockClient(connection: Fixtures.connection())
        let id = client.connection.id
        let local = Fixtures.bookID("local", connection: id)
        let remoteBook = Fixtures.bookID("remote", connection: id)
        client.update { $0.authorizeProgress = [Fixtures.progress(remoteBook, id: "server-remote", currentTime: 50, lastUpdate: .now)] }
        let hearth = makeHearth([client])

        await hearth.progress.update(local, currentTime: 10, duration: 100)
        await hearth.progress.sync()

        let pushed = client.read { $0.pushedProgress.flatMap { $0 } }
        #expect(pushed.map(\.itemID) == [local])
        #expect(hearth.progress.record(for: local)?.status == .synced)
        #expect(hearth.progress.progress(for: remoteBook)?.id == "server-remote")
        #expect(hearth.progress.record(for: remoteBook)?.status == .synced)
    }

    @Test func syncKeepsRecordsOfUnresolvedItems() async {
        let client = MockClient(connection: Fixtures.connection())
        let book = Fixtures.bookID("b1", connection: client.connection.id)
        client.update { $0.authorizeProgress = [Fixtures.progress(book, id: "server", currentTime: 40, lastUpdate: Fixtures.date(0))] }
        let hearth = makeHearth([client])
        await hearth.progress.sync()
        #expect(hearth.progress.record(for: book)?.status == .synced)

        // The item's library lookup failed this time: the entry is missing from the response but not deleted.
        client.update {
            $0.authorizeProgress = []
            $0.authorizeUnresolved = [book.apiItemID]
        }
        await hearth.progress.sync()
        #expect(hearth.progress.progress(for: book)?.currentTime == 40)
    }

    @Test func syncKeepsRecordsChangedWhileAuthorizing() async throws {
        let client = MockClient(connection: Fixtures.connection())
        client.update { $0.authorizeDelay = .milliseconds(300) }
        let book = Fixtures.bookID("b1", connection: client.connection.id)
        let hearth = makeHearth([client])

        // A live update arrives while the (older) authorize response is in flight.
        let sync = Task { await hearth.progress.sync() }
        await client.waitForAuthorize()
        await hearth.progress.applyLive(Fixtures.progress(book, id: "server", currentTime: 25, lastUpdate: .now))
        await sync.value
        #expect(hearth.progress.progress(for: book)?.currentTime == 25)
    }

    @Test func resetKeepsTombstoneUntilServerDeleteSucceeds() async throws {
        let client = MockClient(connection: Fixtures.connection())
        let book = Fixtures.bookID("b1", connection: client.connection.id)
        let remote = Fixtures.progress(book, id: "server", currentTime: 40, lastUpdate: Fixtures.date(0))
        client.update {
            $0.authorizeProgress = [remote]
            $0.failProgressDeletes = true
        }
        let hearth = makeHearth([client])
        await hearth.progress.sync()
        #expect(hearth.progress.progress(for: book) != nil)

        try await hearth.progress.reset(book)
        #expect(hearth.progress.progress(for: book) == nil)
        #expect(hearth.progress.record(for: book)?.status == .tombstone)

        client.update { $0.failProgressDeletes = false }
        await hearth.progress.sync()
        #expect(client.read { $0.deletedProgress } == ["server"])
        #expect(hearth.progress.record(for: book) == nil)
    }

    @Test func setFinishedPushesImmediately() async throws {
        let client = MockClient(connection: Fixtures.connection())
        let book = Fixtures.bookID("b1", connection: client.connection.id)
        let hearth = makeHearth([client])
        await hearth.progress.update(book, currentTime: 10, duration: 100)

        try await hearth.progress.setFinished(book, finished: true)

        let pushed = client.read { $0.pushedProgress.last ?? [] }
        #expect(pushed.first?.isFinished == true)
        #expect(pushed.first?.currentTime == 100)
        #expect(hearth.progress.record(for: book)?.status == .synced)
        #expect(hearth.progress.inProgress().isEmpty)
    }

    @Test func setFinishedOfflineStaysDirty() async throws {
        let client = MockClient(connection: Fixtures.connection())
        client.update { $0.failAll = true }
        let book = Fixtures.bookID("b1", connection: client.connection.id)
        let hearth = makeHearth([client])

        try await hearth.progress.setFinished(book, finished: true)
        #expect(hearth.progress.record(for: book)?.status == .dirty)
        #expect(hearth.progress.isFinished(book))
    }

    @Test func inProgressIsNewestFirstAndSkipsHidden() async throws {
        let client = MockClient(connection: Fixtures.connection())
        let id = client.connection.id
        let a = Fixtures.bookID("a", connection: id)
        let b = Fixtures.bookID("b", connection: id)
        let c = Fixtures.bookID("c", connection: id)
        let hearth = makeHearth([client])
        await hearth.progress.update(a, currentTime: 10, duration: 100)
        await hearth.progress.update(b, currentTime: 10, duration: 100)
        await hearth.progress.update(c, currentTime: 10, duration: 100)
        try await hearth.progress.hideFromContinueListening(b)

        #expect(hearth.progress.inProgress().map(\.itemID) == [c, a])
    }

    @Test func liveEventUpdatesSyncedRecord() async {
        let client = MockClient(connection: Fixtures.connection())
        let book = Fixtures.bookID("b1", connection: client.connection.id)
        let hearth = makeHearth([client])

        await hearth.handle(.progressUpdated(Fixtures.progress(book, id: "server", currentTime: 70, lastUpdate: .now)), connection: client.connection.id)
        #expect(hearth.progress.progress(for: book)?.currentTime == 70)
    }
}
