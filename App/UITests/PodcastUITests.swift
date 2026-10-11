import XCTest

/// Podcast episode playback: Up Next per podcast settings, auto-advance to the next episode.
final class PodcastUITests: HearthUITestCase {
    func testEpisodeUpNextAndAutoAdvance() async throws {
        let podcast = try await server.items()["The Reading Room"]
        let podcastID = try XCTUnwrap(podcast?.id)
        try await server.resetItem(podcastID)
        let episodes = try await server.item(podcastID).media.episodes ?? []
        // The oldest episode, resumed 20 s before its end so that skipping forward finishes it.
        let first = try XCTUnwrap(episodes.min { ($0.publishedAt ?? 0) < ($1.publishedAt ?? 0) })
        let duration = try XCTUnwrap(first.duration)
        try await server.setProgress(itemID: podcastID, episodeID: first.id, body: ["currentTime": duration - 20, "duration": duration, "progress": (duration - 20) / duration])

        launchSignedIn()
        waitForMainUI()
        selectLibrary("Podcasts")
        selectTab("Library")
        waitFor(button(containing: "The Reading Room"), timeout: 30).tap()
        let row = element(containing: first.title)
        scrollTo(row)
        waitFor(row, timeout: 20).tap()
        waitFor(app.buttons["playButton"], timeout: 20, "Episode detail did not load")
        startPlaybackAndOpenPlayer()
        XCTAssertTrue(waitForElapsed(atLeast: 1), "Episode playback does not advance")

        // Up Next lists other (unfinished) episodes of the podcast.
        app.buttons["player.panelToggle"].tap()
        waitFor(app.buttons["Queue"], timeout: 10).tap()
        waitFor(app.staticTexts["Up Next"], timeout: 10, "Up Next missing")
        let others = episodes.filter { $0.id != first.id }
        let anyOther = NSCompoundPredicate(orPredicateWithSubpredicates: others.map { NSPredicate(format: "label CONTAINS %@", $0.title) })
        let upNext = app.buttons.matching(anyOther).firstMatch
        waitFor(upNext, timeout: 10, "No episodes in Up Next")
        let upNextLabel = upNext.label
        let next = try XCTUnwrap(others.first { upNextLabel.contains($0.title) })
        let nextTitle = next.title
        app.buttons["player.panelToggle"].tap()

        // Skip past the end: the episode finishes and the next one starts.
        app.buttons["player.skipForward"].tap()
        idle(1)
        app.buttons["player.skipForward"].tap()

        let server = self.server!
        try await eventually(timeout: 40, "\(first.title) not finished on the server") {
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
