import XCTest

/// Library grid → detail with chapters, Series → books, Search, podcast library → episodes.
final class BrowseUITests: HearthUITestCase {
    func testLibraryGridOpensAudiobookWithChapters() throws {
        launchSignedIn()
        waitForMainUI()
        selectLibrary("Audiobooks")
        selectTab("Library")

        tapVisible(itemCell("Frankenstein"))

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

        let series = waitFor(itemCell("Sherlock Holmes"), timeout: 30, "Series missing")
        series.tap()

        let books = ["A Study in Scarlet", "The Sign of the Four", "The Hound of the Baskervilles"]
        waitFor(button(containing: books[0]), timeout: 20, "Series books did not load")
        for title in books {
            let book = button(containing: title)
            if !book.exists {
                scrollTo(book)
            }
            XCTAssertTrue(book.waitForExistence(timeout: 10), "\(title) missing from series")
        }
    }

    func testSearchFindsSherlockBooks() throws {
        launchSignedIn()
        waitForMainUI()
        selectLibrary("Audiobooks")

        let searchTab = app.tabBars.buttons["Search"]
        waitFor(searchTab).tap()
        let field = waitFor(app.searchFields.firstMatch)
        field.tap()
        field.typeText("the")

        XCTAssertTrue(element(containing: "The Sign of the Four").waitForExistence(timeout: 20), "No search results")
        XCTAssertTrue(element(containing: "The Hound of the Baskervilles").exists)
    }

    func testPodcastLibraryShowsEpisodes() async throws {
        // The podcast page lists unfinished episodes by default; start from a clean slate.
        let podcastID = try await server.itemID(title: "The Reading Room")
        try await server.resetItem(podcastID)
        launchSignedIn()
        waitForMainUI()

        selectLibrary("Podcasts")
        selectTab("Home")

        let podcast = waitFor(button(containing: "The Reading Room"), timeout: 30, "Podcast missing on podcast home")
        podcast.tap()

        // Newest first.
        let episode = element(containing: "Little Women, Big Ideas")
        scrollTo(episode)
        XCTAssertTrue(episode.waitForExistence(timeout: 20), "Episodes not listed")
        let other = element(containing: "Great Expectations and the Dickens Machine")
        scrollTo(other)
        XCTAssertTrue(other.exists, "Only one episode listed")
    }
}
