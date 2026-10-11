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
}
