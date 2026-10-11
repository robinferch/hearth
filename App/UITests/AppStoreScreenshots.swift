import CryptoKit
import XCTest

/// Captures the App Store marketing screenshots against the demo library (see `Marketing/AppStore/assets/demo-library`).
///
/// Only runs when `HEARTH_SCREENSHOT_DIR` is set (`TEST_RUNNER_HEARTH_SCREENSHOT_DIR` via `xcodebuild`); writes full
/// resolution PNGs there. Prepare the simulator first (status bar override, light appearance, en_US region):
///
///     xcrun simctl status_bar <udid> override --time 9:41 --dataNetwork wifi --wifiBars 3 --cellularMode active \
///         --cellularBars 4 --batteryState charged --batteryLevel 100
///     xcrun simctl ui <udid> appearance light
///     TEST_RUNNER_HEARTH_SCREENSHOT_DIR=$PWD/Marketing/AppStore/assets/screens xcodebuild test -project Hearth.xcodeproj \
///         -scheme Hearth -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
///         -only-testing:HearthUITests/AppStoreScreenshots
///
/// `testIPhone` runs on iPhone destinations, `testIPad` (landscape) on iPad destinations.
final class AppStoreScreenshots: HearthUITestCase {
    private static var directory: URL? {
        ProcessInfo.processInfo.environment["HEARTH_SCREENSHOT_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    private static var user: String { ProcessInfo.processInfo.environment["HEARTH_SCREENSHOT_USER"] ?? "root" }
    private static var userPassword: String { ProcessInfo.processInfo.environment["HEARTH_SCREENSHOT_PASSWORD"] ?? "hearth" }

    private var items: [String: ServerAPI.LibraryItem] = [:]

    override func setUp() async throws {
        guard Self.directory != nil else {
            throw XCTSkip("Set HEARTH_SCREENSHOT_DIR (TEST_RUNNER_HEARTH_SCREENSHOT_DIR) to capture App Store screenshots")
        }
        continueAfterFailure = false
        server = try await ServerAPI.login(host: Self.server, username: Self.user, password: Self.userPassword)
        items = try await server.items()
        // Same starting point on every run: mid-chapter in Moby-Dick, 62 % into The Hound of the Baskervilles.
        try await setProgress("Moby-Dick", fraction: 0.35)
        try await setProgress("The Hound of the Baskervilles", fraction: 0.62)
    }

    // MARK: iPhone

    func testIPhone() async throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "iPhone only")
        launch(reset: true)
        waitForMainUI()
        selectLibrary("Audiobooks")

        // Player at 1.3×.
        let close = play("Moby-Dick")
        setSpeed("1.3×")
        capture("iphone-player")

        app.buttons["player.panelToggle"].tap()
        idle(1)
        capture("iphone-player-chapters")
        app.buttons["player.panelToggle"].tap()
        idle(1)

        // Sleep timer: the preset menu, then an active timer with its countdown in the action row.
        let sleepTimer = app.buttons["Sleep timer"]
        sleepTimer.tap()
        let preset = waitFor(app.buttons["30 minutes"], timeout: 5, "Sleep timer menu missing")
        capture("iphone-sleep-timer")
        preset.tap()
        idle(3)
        capture("iphone-sleep-timer-active")

        close.tap()
        waitFor(app.descendants(matching: .any)["miniPlayer"], timeout: 15, "Mini player missing")

        // Downloads first, so the Downloaded screen (and the Home shelf) have content.
        for title in ["The Hound of the Baskervilles", "Pride and Prejudice", "Dracula"] {
            download(title)
        }

        openDeepLink("hearth://item/\(identifier(.audiobook, "The Hound of the Baskervilles"))")
        waitFor(app.buttons["playButton"], timeout: 20, "Detail did not load")
        capture("iphone-audiobook")

        tapVisible(button(containing: "Sherlock Holmes"))
        waitFor(itemCell("A Study in Scarlet"), timeout: 20, "Series did not load")
        capture("iphone-series")

        selectTab("Library")
        popToRoot()
        tapVisible(waitFor(button(containing: "Downloaded"), timeout: 20, "Downloaded shortcut missing"))
        waitFor(element(containing: "Dracula"), timeout: 20, "Downloads missing")
        capture("iphone-downloads")
        popToRoot()

        selectTab("Home")
        popToRoot()
        waitFor(itemCell("Moby-Dick"), timeout: 30, "Home did not load")
        capture("iphone-home")

        openDeepLink("hearth://statistics")
        waitFor(app.navigationBars["Statistics"], timeout: 20, "Statistics did not open")
        capture("iphone-statistics")

        openDeepLink("hearth://search?q=the")
        waitFor(element(containing: "The War of the Worlds"), timeout: 20, "Search results missing")
        dismissKeyboard()
        capture("iphone-search")

        openDeepLink("hearth://item/\(identifier(.podcast, "The Reading Room"))")
        waitFor(element(containing: "Little Women, Big Ideas"), timeout: 20, "Podcast did not load")
        capture("iphone-podcast")

        // Library grid without the shortcut rows (relaunch: the setting is read at launch).
        relaunch(shortcuts: "")
        waitForMainUI()
        selectLibrary("Audiobooks")
        selectTab("Library")
        waitFor(itemCell("Frankenstein"), timeout: 30, "Library grid did not load")
        capture("iphone-library")

        // Dark appearance: relaunch with the app's color scheme setting overridden.
        relaunch(dark: true)
        waitForMainUI()
        let darkClose = play("Moby-Dick")
        setSpeed("1.3×")
        capture("iphone-player-dark")
        darkClose.tap()
        selectTab("Home")
        popToRoot()
        waitFor(itemCell("Moby-Dick"), timeout: 30, "Home did not load (dark)")
        capture("iphone-home-dark")
        pause()
    }

    // MARK: iPad

    func testIPad() async throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only")
        useFullScreenApps()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        // Navigate by UI only: opening `hearth://` URLs leaves a "Hearth" breadcrumb in the iPad status bar.
        launch(reset: true, shortcuts: "")
        waitForMainUI()
        let sidebarToggle = app.buttons["ToggleSidebar"]
        if !app.staticTexts["Podcasts"].waitForExistence(timeout: 5), sidebarToggle.exists {
            sidebarToggle.tap()
        }
        sidebarEntry("Home").tap()
        waitFor(itemCell("Moby-Dick"), timeout: 30, "Home did not load")
        // Moby-Dick is the last played item (see setUp): resume it from the mini player.
        let resume = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "miniPlayer.playPause", "Resume")).firstMatch
        waitFor(resume, timeout: 20, "Mini player missing").tap()
        idle(2)
        let close = waitForPlayer()
        setSpeed("1.3×")
        capture("ipad-player")
        close.tap()

        popToRoot()
        waitFor(itemCell("Moby-Dick"), timeout: 30, "Home did not load")
        capture("ipad-home")

        tapUntil(itemCell("The Hound of the Baskervilles"), shows: app.buttons["playButton"], "Detail did not load")
        capture("ipad-audiobook")

        sidebarEntry("Library").tap()
        waitFor(itemCell("Little Women"), timeout: 30, "Library grid did not load")
        capture("ipad-library")
        pause()
    }

    // MARK: Helpers

    private enum Kind: String {
        case audiobook
        case podcast
    }

    private func relaunch(dark: Bool = false, shortcuts: String = "series,authors,collections,downloaded") {
        pause()
        app.terminate()
        launch(reset: false, dark: dark, shortcuts: shortcuts)
    }

    private func launch(reset: Bool, dark: Bool = false, shortcuts: String = "series,authors,collections,downloaded") {
        let app = XCUIApplication()
        var arguments = ["-HearthDebugLogin", Self.server, Self.user, Self.userPassword]
        if reset {
            arguments.append("-HearthDebugReset")
        }
        arguments += [
            "-HearthDisableTips", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            // App settings (app group defaults) and `@AppStorage` values can be overridden for this run only.
            "-colorScheme", dark ? "dark" : "light",
            "-library.shortcuts", shortcuts,
        ]
        app.launchArguments = arguments
        app.launch()
        self.app = app
    }

    /// Same derivation as `Connection.makeID(host:username:)`.
    private func connectionID() -> String {
        let digest = SHA256.hash(data: Data("host:\(Self.server).user:\(Self.user)".utf8))
        return String(Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            .prefix(22))
    }

    private func identifier(_ kind: Kind, _ title: String) -> String {
        guard let item = items[title] else {
            XCTFail("\(title) is missing on the server — seed the demo library first")
            return ""
        }
        return "\(kind.rawValue)::\(connectionID())::\(item.libraryId)::\(item.id)"
    }

    private func setProgress(_ title: String, fraction: Double) async throws {
        guard let item = items[title] else { return }
        let full = try await server.item(item.id)
        let duration = full.media.chapters?.last?.end ?? 0
        try await server.setProgress(itemID: item.id, body: ["currentTime": duration * fraction, "duration": duration, "progress": fraction])
    }

    /// Delivers a `hearth://` URL to the running app (`XCUIApplication.open` would relaunch it with the debug
    /// launch arguments, resetting the connection and restarting playback).
    private func openDeepLink(_ url: String) {
        XCUIDevice.shared.system.open(URL(string: url)!)
        let confirm = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if confirm.waitForExistence(timeout: 3) {
            confirm.tap()
        }
        idle(1.5)
    }

    /// Starts `title` via `hearth://play` and returns the full player's close button (a new item opens the player
    /// automatically, a resumed one is opened from the mini player).
    @discardableResult
    private func play(_ title: String) -> XCUIElement {
        openDeepLink("hearth://play/\(identifier(.audiobook, title))")
        return waitForPlayer()
    }

    private func waitForPlayer() -> XCUIElement {
        let close = app.buttons["player.close"]
        if !close.waitForExistence(timeout: 15) {
            waitFor(app.descendants(matching: .any)["miniPlayer.title"], timeout: 20, "Mini player missing").tap()
        }
        return waitFor(close, timeout: 15, "Player did not open")
    }

    private func setSpeed(_ label: String) {
        // The iPad player can contain more than one speed control (e.g. behind the full-screen cover).
        let candidates = app.buttons.matching(identifier: "Playback speed")
        waitFor(candidates.firstMatch, timeout: 10, "Speed button missing")
        let speed = candidates.allElementsBoundByIndex.first { $0.isHittable } ?? candidates.firstMatch
        var taps = 0
        while speed.value as? String != label, taps < 6 {
            speed.tap()
            taps += 1
            idle(0.6)
        }
    }

    private func download(_ title: String) {
        openDeepLink("hearth://item/\(identifier(.audiobook, title))")
        let button = waitFor(app.buttons["detail.download"], timeout: 20, "Download button missing for \(title)")
        if button.label != "Downloaded" {
            button.tap()
        }
        let deadline = Date.now.addingTimeInterval(90)
        while Date.now < deadline, button.label != "Downloaded" {
            idle(1)
        }
        XCTAssertEqual(button.label, "Downloaded", "Download of \(title) did not complete")
    }

    /// Windowed apps (the iPadOS default) add the app name to the status bar and a resize grabber: switch the
    /// simulator to full screen apps in Settings › Multitasking & Gestures.
    private func useFullScreenApps() {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        let any = settings.descendants(matching: .any)
        let multitasking = any.matching(NSPredicate(format: "label == %@", "Multitasking & Gestures")).firstMatch
        if multitasking.waitForExistence(timeout: 10) {
            multitasking.tap()
            let fullScreen = any.matching(NSPredicate(format: "label BEGINSWITH %@", "Full Screen Apps")).firstMatch
            if fullScreen.waitForExistence(timeout: 10) {
                fullScreen.tap()
                idle(2)
            } else {
                print("Settings hierarchy:\n\(settings.debugDescription)")
            }
        }
        settings.terminate()
    }

    /// Taps `element` (again, if the first tap was swallowed) until `target` appears.
    private func tapUntil(_ element: XCUIElement, shows target: XCUIElement, _ message: String) {
        waitFor(element, timeout: 30, message)
        for _ in 0..<3 where !target.exists {
            element.tap()
            _ = target.waitForExistence(timeout: 8)
        }
        waitFor(target, timeout: 5, message)
    }

    private func sidebarEntry(_ label: String) -> XCUIElement {
        let entry = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        return waitFor(entry, timeout: 15, "Sidebar entry \(label) missing")
    }

    /// Pops the selected tab's navigation stack by tapping its back buttons.
    private func popToRoot() {
        for _ in 0..<5 {
            let back = app.navigationBars.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "BackButton", "Back")).firstMatch
            guard back.exists, back.isHittable else { return }
            back.tap()
            idle(0.8)
        }
    }

    private func dismissKeyboard() {
        guard app.keyboards.firstMatch.exists else { return }
        let search = app.keyboards.buttons.matching(NSPredicate(format: "label IN %@", ["search", "Search"])).firstMatch
        if search.exists {
            search.tap()
        }
        idle(1)
    }

    private func pause() {
        let playPause = app.descendants(matching: .any)["miniPlayer.playPause"]
        if playPause.exists, playPause.label == "Pause" {
            playPause.tap()
        }
    }

    /// Full-resolution PNG with the orientation applied (landscape iPad screenshots of full-screen covers otherwise
    /// come out rotated).
    private static func uprightPNG(_ screenshot: XCUIScreenshot) -> Data {
        let image = screenshot.image
        guard image.imageOrientation != .up else { return screenshot.pngRepresentation }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).pngData { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    /// Waits for spinners to disappear and covers to load, then writes a full-resolution PNG.
    private func capture(_ name: String) {
        let deadline = Date.now.addingTimeInterval(15)
        while Date.now < deadline, app.activityIndicators.matching(NSPredicate(format: "exists == true")).count > 0 {
            idle(0.5)
        }
        idle(2.5)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory = Self.directory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.uprightPNG(screenshot).write(to: directory.appending(path: "\(name).png"))
        } catch {
            XCTFail("Could not write \(name): \(error)")
        }
    }
}
