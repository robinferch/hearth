import XCTest

/// Library grid → detail with chapters, Series → books, Search, podcast library → episodes.
final class BrowseUITests: HearthUITestCase {
    func testLibraryGridOpensAudiobookWithChapters() throws {
        launchSignedIn()
        waitForMainUI()
        selectLibrary("Audiobooks")
        selectTab("Library")

        let frankenstein = waitFor(itemCell("Frankenstein"), timeout: 30, "Frankenstein not in library grid")
        frankenstein.tap()

        waitFor(app.buttons["playButton"], timeout: 20, "Detail did not load")
        let chapters = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Chapters")).firstMatch
        scrollTo(chapters)
        waitFor(chapters, timeout: 10, "Chapters section missing")
        chapters.tap()
        let chapter = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Chapter 4")).firstMatch
        scrollTo(chapter)
        XCTAssertTrue(chapter.waitForExistence(timeout: 5), "Chapter rows not shown")
    }

    func testSeriesShowsBooks() throws {
        launchSignedIn()
        waitForMainUI()
        selectLibrary("Audiobooks")
        selectTab("Series")

        let series = waitFor(button(containing: "Sherlock Holmes"), timeout: 30, "Series missing")
        series.tap()

        for number in 1...3 {
            let book = button(containing: "Sherlock Holmes \(number)")
            scrollTo(book)
            XCTAssertTrue(book.waitForExistence(timeout: 15), "Book \(number) missing from series")
        }
    }

    func testSearchFindsSherlock() throws {
        launchSignedIn()
        waitForMainUI()
        selectLibrary("Audiobooks")

        let searchTab = app.tabBars.buttons["Search"]
        waitFor(searchTab).tap()
        let field = waitFor(app.searchFields.firstMatch)
        field.tap()
        field.typeText("sherlock")

        XCTAssertTrue(element(containing: "Sherlock Holmes 1").waitForExistence(timeout: 20), "No search results")
        XCTAssertTrue(element(containing: "Sherlock Holmes 2").exists)
    }

    func testPodcastLibraryShowsEpisodes() async throws {
        // The podcast page lists unfinished episodes by default; start from a clean slate.
        let podcastID = try await server.itemID(title: "Hearth Test Podcast")
        try await server.resetItem(podcastID)
        launchSignedIn()
        waitForMainUI()

        selectLibrary("Podcasts")
        selectTab("Home")

        let podcast = waitFor(button(containing: "Hearth Test Podcast"), timeout: 30, "Podcast missing on podcast home")
        podcast.tap()

        let episode = element(containing: "Episode 1")
        scrollTo(episode)
        XCTAssertTrue(episode.waitForExistence(timeout: 20), "Episodes not listed")
        let others = app.descendants(matching: .any).matching(NSPredicate(format: "label MATCHES %@", ".*Episode [2-4].*")).firstMatch
        scrollTo(others)
        XCTAssertTrue(others.exists, "Only one episode listed")
    }
}
