import XCTest

/// Walks the main screens in German and attaches screenshots (review for untranslated strings).
/// Set `HEARTH_UITEST_SCREENSHOT_DIR` to also write the PNGs to a directory.
final class LocalizationScreenshotTests: HearthUITestCase {
    private var index = 0

    private func capture(_ name: String) {
        RunLoop.current.run(until: .now.addingTimeInterval(1.5))
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["HEARTH_UITEST_SCREENSHOT_DIR"] {
            index += 1
            let url = URL(fileURLWithPath: directory).appending(path: String(format: "%02d-%@.png", index, name))
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: url)
        }
    }

    private func tab(_ index: Int) -> XCUIElement {
        app.tabBars.buttons.element(boundBy: index)
    }

    func testGermanScreens() throws {
        launchSignedIn(language: "de", locale: "de_DE")
        waitFor(app.buttons["libraryPicker"], timeout: 40)
        selectLibrary("Audiobooks")
        waitFor(tab(0)).tap()
        capture("home")

        tab(1).tap()
        waitFor(itemCell("Frankenstein"), timeout: 30)
        capture("library")

        tab(2).tap()
        capture("series")
        tab(3).tap()
        capture("authors")

        tab(1).tap()
        itemCell("Frankenstein").tap()
        waitFor(app.buttons["playButton"], timeout: 20)
        capture("detail")
        app.swipeUp()
        capture("detail-sections")

        app.buttons["playButton"].firstMatch.tap()
        let close = app.buttons["player.close"]
        if !close.waitForExistence(timeout: 15) {
            waitFor(app.descendants(matching: .any)["miniPlayer.title"]).tap()
        }
        waitFor(close)
        app.buttons["player.playPause"].tap()
        capture("player")
        app.buttons["player.panelToggle"].tap()
        capture("player-panel")
        close.tap()
        capture("mini-player")

        // Context menu of a library item.
        itemCell("Frankenstein").press(forDuration: 1.2)
        capture("context-menu")
        app.tap()

        app.tabBars.buttons.element(boundBy: app.tabBars.buttons.count - 1).tap()
        let field = waitFor(app.searchFields.firstMatch)
        field.tap()
        field.typeText("sherlock")
        RunLoop.current.run(until: .now.addingTimeInterval(3))
        capture("search")

        waitFor(app.buttons["libraryPicker"]).tap()
        capture("library-picker")
        app.buttons.element(boundBy: 0).tap()

        selectLibrary("Podcasts")
        waitFor(tab(0)).tap()
        capture("podcast-home")
        tab(1).tap()
        capture("podcast-latest")

        waitFor(app.buttons["libraryPicker"]).tap()
        let settings = app.buttons.matching(NSPredicate(format: "label == %@", "Einstellungen")).firstMatch
        waitFor(settings).tap()
        capture("settings")
        let cells = ["Darstellung", "Wiedergabe", "Schlaftimer", "Mediathek", "Downloads", "Tagesziel"]
        for cell in cells {
            let entry = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", cell)).firstMatch
            guard entry.waitForExistence(timeout: 3) else { continue }
            entry.tap()
            capture("settings-\(cell)")
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
    }
}
