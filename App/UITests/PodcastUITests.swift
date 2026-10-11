import XCTest

/// Podcast episode playback: Up Next per podcast settings, auto-advance to the next episode.
final class PodcastUITests: HearthUITestCase {
    func testEpisodeUpNextAndAutoAdvance() async throws {
        let podcast = try await server.items()["Hearth Test Podcast"]
        let podcastID = try XCTUnwrap(podcast?.id)
        try await server.resetItem(podcastID)
        let episodes = try await server.item(podcastID).media.episodes ?? []
        let first = try XCTUnwrap(episodes.first { $0.title == "Episode 1" })

        launchSignedIn()
        waitForMainUI()
        selectLibrary("Podcasts")
        selectTab("Library")
        waitFor(button(containing: "Hearth Test Podcast"), timeout: 30).tap()
        let row = element(containing: "Episode 1")
        scrollTo(row)
        waitFor(row, timeout: 20).tap()
        waitFor(app.buttons["playButton"], timeout: 20, "Episode detail did not load")
        startPlaybackAndOpenPlayer()
        XCTAssertTrue(waitForElapsed(atLeast: 1), "Episode playback does not advance")

        // Up Next lists other (unfinished) episodes of the podcast.
        app.buttons["player.panelToggle"].tap()
        waitFor(app.buttons["Queue"], timeout: 10).tap()
        waitFor(app.staticTexts["Up Next"], timeout: 10, "Up Next missing")
        let upNext = app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*Episode [2-9].*")).firstMatch
        waitFor(upNext, timeout: 10, "No episodes in Up Next")
        let nextTitle = try XCTUnwrap(episodes.map(\.title).first { upNext.label.contains($0) && $0 != "Episode 1" })
        let next = try XCTUnwrap(episodes.first { $0.title == nextTitle })
        app.buttons["player.panelToggle"].tap()

        // Skip to the end (60 s episode): it finishes and the next one starts.
        app.buttons["player.skipForward"].tap()
        idle(1)
        app.buttons["player.skipForward"].tap()

        let server = self.server!
        try await eventually(timeout: 40, "Episode 1 not finished on the server") {
            try await server.progress(itemID: podcastID, episodeID: first.id)?.isFinished == true
        }
        XCTAssertTrue(element(containing: nextTitle).waitForExistence(timeout: 20), "\(nextTitle) did not start")
        try await eventually(timeout: 40, "\(nextTitle) has no server progress") {
            (try await server.progress(itemID: podcastID, episodeID: next.id)?.currentTime ?? 0) > 0
        }
        if app.buttons["player.playPause"].label == "Pause" {
            app.buttons["player.playPause"].tap()
        }
    }
}
