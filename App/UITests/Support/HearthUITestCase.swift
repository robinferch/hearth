import XCTest

/// Base class for Hearth UI tests against a live audiobookshelf server.
///
/// The server defaults to `http://localhost:13380`; override with the `HEARTH_UITEST_SERVER`, `HEARTH_UITEST_USER`
/// and `HEARTH_UITEST_PASSWORD` environment variables (set them in the scheme / `TEST_RUNNER_` prefixed for
/// `xcodebuild`). Tests that verify server state use their own account so they don't interfere with other clients.
@MainActor
class HearthUITestCase: XCTestCase {
    static var server: String { ProcessInfo.processInfo.environment["HEARTH_UITEST_SERVER"] ?? "http://localhost:13380" }
    static var username: String { ProcessInfo.processInfo.environment["HEARTH_UITEST_USER"] ?? "hearthqa" }
    static var password: String { ProcessInfo.processInfo.environment["HEARTH_UITEST_PASSWORD"] ?? "hearth" }

    var app: XCUIApplication!
    var server: ServerAPI!

    override func setUp() async throws {
        continueAfterFailure = false
        server = try await ServerAPI.login(host: Self.server, username: Self.username, password: Self.password)
    }

    /// Launches the app signed in with the test account (all other connections removed).
    @discardableResult
    func launchSignedIn(_ extraArguments: [String] = [], reset: Bool = true, language: String = "en", locale: String = "en_US") -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["-HearthDebugLogin", Self.server, Self.username, Self.password]
        if reset {
            arguments.append("-HearthDebugReset")
        }
        // Keep TipKit popovers out of the way and use a fixed UI language.
        arguments += ["-HearthDisableTips", "YES", "-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        app.launchArguments = arguments + extraArguments
        app.launch()
        self.app = app
        return app
    }

    // MARK: Player helpers

    /// Opens an audiobook from the Library tab.
    func openAudiobook(_ title: String) {
        waitForMainUI()
        selectLibrary("Audiobooks")
        selectTab("Library")
        waitFor(itemCell(title), timeout: 30, "\(title) not in library").tap()
        waitFor(app.buttons["playButton"], timeout: 20, "Detail of \(title) did not load")
    }

    /// Starts playback from the detail screen and makes sure the full player is open.
    func startPlaybackAndOpenPlayer() {
        app.buttons["playButton"].firstMatch.tap()
        openPlayer()
    }

    /// Opens the full player (closing it first when it opened automatically, to check the mini player).
    func openPlayer() {
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

    func elapsed() -> TimeInterval {
        let label = app.staticTexts["player.elapsed"]
        guard label.waitForExistence(timeout: 10) else { return -1 }
        return Self.seconds(fromClock: label.label) ?? -1
    }

    func waitForElapsed(atLeast seconds: TimeInterval, timeout: TimeInterval = 20) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if elapsed() >= seconds {
                return true
            }
            RunLoop.current.run(until: .now.addingTimeInterval(0.5))
        }
        return false
    }

    /// Lets the app run for `seconds` (usable from async tests, unlike `RunLoop.run`).
    func idle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: .now.addingTimeInterval(seconds))
    }

    // MARK: Element helpers

    func element(containing text: String, in query: XCUIElementQuery? = nil) -> XCUIElement {
        let query = query ?? app.descendants(matching: .any)
        return query.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    /// Grid / list cell of an item ("Audiobook: Title", localized prefix) — not the mini player or other mentions.
    func itemCell(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label ENDSWITH %@ OR label BEGINSWITH %@", ": \(title)", "\(title),")).firstMatch
    }

    func button(containing text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    @discardableResult
    func waitFor(_ element: XCUIElement, timeout: TimeInterval = 20, _ message: String? = nil, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let exists = element.waitForExistence(timeout: timeout)
        if !exists, let app {
            print("UI hierarchy when waiting for \(element) failed:\n\(app.debugDescription)")
        }
        XCTAssertTrue(exists, message ?? "Timed out waiting for \(element)", file: file, line: line)
        return element
    }

    /// Waits until the main UI (tab bar with library content) is visible.
    func waitForMainUI(timeout: TimeInterval = 40, file: StaticString = #filePath, line: UInt = #line) {
        let home = app.tabBars.buttons["Home"]
        // iPad sidebar rows are cells / other elements, not buttons.
        let sidebarHome = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Home")).firstMatch
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if home.exists || sidebarHome.exists {
                return
            }
            RunLoop.current.run(until: .now.addingTimeInterval(0.5))
        }
        XCTFail("Main UI did not appear", file: file, line: line)
    }

    /// Switches the iPhone tab bar to `library` via the library picker (the last library is restored on launch).
    func selectLibrary(_ library: String, file: StaticString = #filePath, line: UInt = #line) {
        let picker = app.buttons["libraryPicker"]
        waitFor(picker, timeout: 20, "Library picker missing", file: file, line: line)
        // Library roots are titled with the library name.
        if picker.value as? String == library || app.navigationBars[library].exists {
            return
        }
        let item = app.buttons[library]
        picker.tap()
        if !item.waitForExistence(timeout: 5) {
            // The first tap can be swallowed by a dismissing system sheet (e.g. "Save Password?").
            picker.tap()
        }
        waitFor(item, timeout: 10, "Library \(library) missing in picker", file: file, line: line).tap()
    }

    /// Dismisses the system "Save Password?" sheet if it appears.
    func dismissSavePasswordPrompt(timeout: TimeInterval = 5) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for candidate in [app.buttons["Not Now"], springboard.buttons["Not Now"]] where candidate.waitForExistence(timeout: timeout) {
            candidate.tap()
            return
        }
    }

    /// Selects a tab of the iPhone tab bar.
    func selectTab(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let tab = app.tabBars.buttons[title]
        waitFor(tab, timeout: 20, "Tab \(title) missing", file: file, line: line)
        tab.tap()
    }

    /// Scrolls the frontmost scroll view until `element` is hittable.
    func scrollTo(_ element: XCUIElement, maxSwipes: Int = 8) {
        var swipes = 0
        while !(element.exists && element.isHittable), swipes < maxSwipes {
            app.swipeUp(velocity: .slow)
            swipes += 1
        }
    }

    /// Polls `condition` until it returns true or the timeout expires.
    func eventually(timeout: TimeInterval = 20, interval: TimeInterval = 1, _ message: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () async throws -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if try await condition() {
                return
            }
            try await Task.sleep(for: .seconds(interval))
        }
        XCTFail(message, file: file, line: line)
    }

    /// Parses "m:ss" / "h:mm:ss" clock labels.
    static func seconds(fromClock label: String) -> TimeInterval? {
        let parts = label.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "-−")).split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}
