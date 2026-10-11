import XCTest

/// Settings: skip interval and offline mode.
final class SettingsUITests: HearthUITestCase {
    private func openSettings() {
        waitFor(app.buttons["libraryPicker"], timeout: 20).tap()
        waitFor(app.buttons["Settings"]).tap()
        waitFor(app.navigationBars["Settings"])
    }

    func testChangeSkipInterval() throws {
        launchSignedIn()
        waitForMainUI()
        openSettings()

        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Playback")).firstMatch.tap()
        let picker = waitFor(button(containing: "Skip Forward"))
        picker.tap()
        waitFor(button(containing: "45")).tap()
        let updated = button(containing: "Skip Forward")
        XCTAssertTrue(waitFor(updated).label.contains("45") || (updated.value as? String)?.contains("45") == true, "Skip forward interval not updated: \(updated.label) / \(String(describing: updated.value))")

        // Restore the default.
        button(containing: "Skip Forward").tap()
        waitFor(button(containing: "30")).tap()
    }

    func testOfflineModeToggle() throws {
        launchSignedIn()
        waitForMainUI()
        openSettings()

        let toggle = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "Offline Mode")).firstMatch
        waitFor(toggle)
        // The switch control sits at the trailing edge of the row.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1", "Offline toggle did not switch on")

        if app.buttons["Done"].exists {
            app.buttons["Done"].tap()
        }
        waitFor(app.navigationBars["Offline"], timeout: 15, "Offline view not shown")
        let goOnline = button(containing: "Go Online")
        waitFor(goOnline).tap()
        waitForMainUI()
        XCTAssertFalse(app.navigationBars["Offline"].exists)
    }
}
