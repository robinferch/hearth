import XCTest

/// Playback, bookmarks and progress — verified against the server.
final class PlaybackUITests: HearthUITestCase {
    /// Opens an audiobook from the Library tab.
    private func openAudiobook(_ title: String) {
        waitForMainUI()
        selectLibrary("Audiobooks")
        selectTab("Library")
        waitFor(button(containing: title), timeout: 30, "\(title) not in library").tap()
        waitFor(app.buttons["playButton"], timeout: 20, "Detail of \(title) did not load")
    }

    /// Starts playback from the detail screen and makes sure the full player is open.
    private func startPlaybackAndOpenPlayer() {
        app.buttons["playButton"].tap()
        let miniPlayer = app.descendants(matching: .any)["miniPlayer"]
        let close = app.buttons["player.close"]
        // A new item opens the full player automatically; otherwise open it from the mini player.
        let deadline = Date.now.addingTimeInterval(20)
        while Date.now < deadline, !close.exists, !miniPlayer.exists {
            RunLoop.current.run(until: .now.addingTimeInterval(0.5))
        }
        if close.exists {
            close.tap()
        }
        waitFor(miniPlayer, timeout: 15, "Mini player did not appear")
        app.descendants(matching: .any)["miniPlayer.title"].tap()
        waitFor(close, timeout: 10, "Full player did not open")
    }

    private func elapsed() -> TimeInterval {
        let label = app.staticTexts["player.elapsed"]
        guard label.waitForExistence(timeout: 10) else { return -1 }
        return Self.seconds(fromClock: label.label) ?? -1
    }

    private func waitForElapsed(atLeast seconds: TimeInterval, timeout: TimeInterval = 20) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if elapsed() >= seconds {
                return true
            }
            RunLoop.current.run(until: .now.addingTimeInterval(0.5))
        }
        return false
    }

    func testPlayFrankensteinSyncsProgress() async throws {
        let itemID = try await server.itemID(title: "Frankenstein")
        try await server.resetItem(itemID)
        let started = Date.now.timeIntervalSince1970 * 1000

        launchSignedIn()
        openAudiobook("Frankenstein")
        startPlaybackAndOpenPlayer()

        let first = elapsed()
        XCTAssertTrue(waitForElapsed(atLeast: first + 2), "Playback time does not advance")

        let beforeSkip = elapsed()
        app.buttons["player.skipForward"].tap()
        XCTAssertTrue(waitForElapsed(atLeast: beforeSkip + 25, timeout: 10), "Skip forward did not move ~30 s (was \(beforeSkip), now \(elapsed()))")

        let playPause = app.buttons["player.playPause"]
        XCTAssertEqual(playPause.label, "Pause")
        playPause.tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5), "Did not pause")
        let pausedAt = elapsed()

        // Pausing reports to the server session; progress must be stored server-side.
        let server = self.server!
        try await eventually(timeout: 30, "Server progress for Frankenstein not updated") {
            guard let progress = try await server.progress(itemID: itemID) else { return false }
            return progress.currentTime > 0 && progress.lastUpdate >= started
        }
        let progress = try await server.progress(itemID: itemID)
        XCTAssertEqual(progress?.currentTime ?? 0, pausedAt, accuracy: 3, "Server time differs from player time")
        let sessions = try await server.sessions().filter { $0.libraryItemId == itemID && $0.updatedAt >= started }
        XCTAssertFalse(sessions.isEmpty, "No listening session recorded on the server")
    }

    func testCreateBookmarkInPlayer() async throws {
        let itemID = try await server.itemID(title: "Emma")
        try await server.resetItem(itemID)
        let note = "UITest \(Int.random(in: 1000...9999))"

        launchSignedIn()
        openAudiobook("Emma")
        startPlaybackAndOpenPlayer()
        XCTAssertTrue(waitForElapsed(atLeast: 2), "Playback did not start")

        waitFor(app.buttons["player.bookmark"]).tap()
        let alert = waitFor(app.alerts["New Bookmark"], timeout: 10, "Bookmark prompt missing")
        let field = alert.textFields.firstMatch
        field.tap()
        field.typeText(note)
        alert.buttons["Create"].tap()

        let server = self.server!
        try await eventually(timeout: 20, "Bookmark not on server") {
            try await server.bookmarks(itemID: itemID).contains { $0.title == note }
        }
        app.buttons["player.playPause"].tap()
    }

    func testMarkFinishedFromContextMenu() async throws {
        let itemID = try await server.itemID(title: "Pride and Prejudice")
        try await server.resetItem(itemID)

        launchSignedIn()
        waitForMainUI()
        selectLibrary("Audiobooks")
        selectTab("Library")
        let cell = waitFor(button(containing: "Pride and Prejudice"), timeout: 30, "Item missing")

        cell.press(forDuration: 1.2)
        waitFor(button(containing: "Mark as finished"), timeout: 10, "Context menu lacks Mark as finished").tap()

        let server = self.server!
        try await eventually(timeout: 20, "Server progress not finished") {
            try await server.progress(itemID: itemID)?.isFinished == true
        }

        cell.press(forDuration: 1.2)
        waitFor(button(containing: "Mark as unfinished"), timeout: 10, "Context menu lacks Mark as unfinished").tap()
        try await eventually(timeout: 20, "Server progress still finished") {
            try await server.progress(itemID: itemID)?.isFinished != true
        }
    }
}
