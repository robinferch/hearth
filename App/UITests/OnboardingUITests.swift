import XCTest

/// Welcome → Add Server → verify → sign in → home, through the real UI.
final class OnboardingUITests: HearthUITestCase {
    func testOnboardingThroughUI() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HearthDebugReset", "-HearthDisableTips", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        self.app = app

        let addServer = waitFor(app.buttons["welcome.addServer"], timeout: 30, "Welcome screen not shown")
        XCTAssertTrue(app.staticTexts["Welcome to Hearth"].exists)
        addServer.tap()

        let host = waitFor(app.textFields["addServer.host"])
        if !host.hasFocus {
            host.tap()
        }
        host.typeText(Self.server)
        app.buttons["addServer.continue"].tap()

        waitFor(app.descendants(matching: .any)["addServer.verified"], timeout: 20, "Server was not verified")
        XCTAssertTrue(element(containing: "Server version").exists)

        let username = waitFor(app.textFields["addServer.username"])
        username.tap()
        username.typeText("root")
        let password = app.secureTextFields["addServer.password"]
        password.tap()
        password.typeText("hearth")

        let signIn = app.buttons["addServer.signIn"]
        XCTAssertTrue(signIn.isEnabled)
        signIn.tap()

        dismissSavePasswordPrompt()
        waitForMainUI()
        selectLibrary("Audiobooks")
        selectTab("Home")
        // Home shows the personalized shelves of the first library.
        let shelf = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Continue Listening", "Recently Added", "Discover"])).firstMatch
        waitFor(shelf, timeout: 30, "Home shelves did not load")
        XCTAssertTrue(app.navigationBars["Audiobooks"].exists || app.staticTexts["Audiobooks"].exists)
    }
}
