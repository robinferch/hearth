import Foundation
@testable import HearthData
import SwiftData
import Testing

@Suite("Persistence")
struct PersistenceTests {
    func makeUnreadableStore() throws -> (directory: URL, store: URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "HearthStore-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = directory.appending(path: "Hearth.store")
        try Data("not a database".utf8).write(to: store)
        return (directory, store)
    }

    @Test func unreadableStoreIsMovedAsideNotDeleted() throws {
        let (directory, store) = try makeUnreadableStore()
        let container = Persistence.makeContainer(url: store, isAppExtension: false)
        let context = ModelContext(container)
        context.upsertLocalSession(LocalSessionRecord(id: "s", itemID: Fixtures.bookID("b", connection: "c"), startTime: 0, currentTime: 1, duration: 2, timeListened: 1, startedAt: .now, updatedAt: .now, isClosed: true))
        #expect(context.localSessions().count == 1)

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let backup = try #require(files.first { $0.hasPrefix("Hearth-unreadable-") && $0.hasSuffix(".store") })
        #expect(try Data(contentsOf: directory.appending(path: backup)) == Data("not a database".utf8))
    }

    @Test func extensionsNeverTouchTheStore() throws {
        let (directory, store) = try makeUnreadableStore()
        _ = Persistence.makeContainer(url: store, isAppExtension: true)
        #expect(try Data(contentsOf: store) == Data("not a database".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["Hearth.store"])
    }
}
