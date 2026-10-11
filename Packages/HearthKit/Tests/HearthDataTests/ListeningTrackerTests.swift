import Foundation
@testable import HearthData
import HearthAPI
import HearthModel
import Testing

@Suite("ListeningTracker")
@MainActor
struct ListeningTrackerTests {
    @Test func staleSessionsAreClosedWithoutProgressAfterSync() async {
        let client = MockClient(connection: Fixtures.connection())
        let book = Fixtures.bookID("b1", connection: client.connection.id)
        let previousRun = makeHearth([client])
        // Local progress is older than what other devices reported to the server since.
        await previousRun.progress.update(book, currentTime: 10, duration: 100)
        previousRun.listening.registerOpenSession("s1", itemID: book)

        // Next launch: the session is still registered as open.
        let hearth = HearthData(environment: previousRun.environment, settings: previousRun.settings)
        await hearth.refresh()

        #expect(client.read { $0.closedSessionsWithoutProgress } == ["s1"])
        #expect(client.read { $0.closedSessions }.isEmpty)
        #expect(client.read { $0.calls } == ["authorize", "close s1"])

        // Closed sessions are forgotten.
        let nextLaunch = HearthData(environment: previousRun.environment, settings: previousRun.settings)
        await nextLaunch.listening.closeStaleSessions()
        #expect(client.read { $0.closedSessionsWithoutProgress } == ["s1"])
    }

    @Test func listeningRecordedDuringUploadIsKept() async throws {
        let client = MockClient(connection: Fixtures.connection())
        client.update { $0.uploadDelay = .milliseconds(300) }
        let book = Fixtures.bookID("b1", connection: client.connection.id)
        let previousRun = makeHearth([client])
        // An open session abandoned two hours ago (the app was killed while playing offline).
        let abandoned = LocalSessionRecord(id: "abandoned", itemID: book, startTime: 0, currentTime: 60, duration: 600, timeListened: 60, startedAt: .now.addingTimeInterval(-7200), updatedAt: .now.addingTimeInterval(-7000), isClosed: false)
        await previousRun.environment.store.perform { $0.upsertLocalSession(abandoned) }
        let hearth = HearthData(environment: previousRun.environment, settings: previousRun.settings)

        let upload = Task { await hearth.listening.uploadPendingSessions() }
        while client.read({ $0.uploadCount }) == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        await hearth.listening.recordLocalSession(itemID: book, startTime: 60, currentTime: 80, duration: 600, timeListened: 20)
        await upload.value

        #expect(client.read { $0.uploadedSessions.map(\.timeListened) } == [60])
        let remaining = await hearth.environment.store.perform { $0.localSessions() }
        #expect(remaining.map(\.timeListened) == [20])
        #expect(remaining.first?.id != "abandoned")
    }
}
