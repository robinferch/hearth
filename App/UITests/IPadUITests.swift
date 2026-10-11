import XCTest

/// iPad: sidebar with per-library sections, navigation and the player. Skipped on iPhone.
final class IPadUITests: HearthUITestCase {
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSidebarNavigationAndPlayer() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }

        launchSignedIn()
        waitForMainUI()

        // Landscape shows the sidebar: Listen Now, Search, one section per library, Settings.
        let sidebarToggle = app.buttons["ToggleSidebar"]
        if !app.staticTexts["Podcasts"].waitForExistence(timeout: 5), sidebarToggle.exists {
            sidebarToggle.tap()
        }
        waitFor(app.staticTexts["Audiobooks"], timeout: 15, "Audiobooks section missing in sidebar")
        XCTAssertTrue(app.staticTexts["Podcasts"].exists, "Podcasts section missing in sidebar")
        XCTAssertTrue(element(containing: "Listen Now").exists)
        attachScreenshot("Sidebar")

        // The first "Library" entry belongs to the audiobook library (libraries are sorted by display order).
        let library = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Library")).firstMatch
        waitFor(library).tap()
        waitFor(itemCell("Frankenstein"), timeout: 30, "Library grid did not load").tap()
        waitFor(app.buttons["playButton"], timeout: 20, "Detail did not load")
        attachScreenshot("Detail")

        app.buttons["playButton"].tap()
        let close = app.buttons["player.close"]
        if !close.waitForExistence(timeout: 15) {
            waitFor(app.descendants(matching: .any)["miniPlayer.title"], timeout: 10, "Mini player missing").tap()
        }
        waitFor(close, timeout: 10, "Player did not open")
        XCTAssertTrue(app.staticTexts["player.elapsed"].waitForExistence(timeout: 10))
        attachScreenshot("Player")
        app.buttons["player.playPause"].tap()
        close.tap()
    }
}
