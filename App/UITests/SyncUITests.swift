import XCTest

/// Downloads + offline playback → upload, and server → app progress (refresh, foreground, Socket.IO).
final class SyncUITests: HearthUITestCase {
    func testDownloadPlayOfflineAndUploadWhenOnline() async throws {
        let itemID = try await server.itemID(title: "The Time Machine")
        try await server.resetItem(itemID)
        let started = Date.now.timeIntervalSince1970 * 1000

        launchSignedIn()
        openAudiobook("The Time Machine")

        // Download and wait until it completes.
        let download = waitFor(app.buttons["detail.download"])
        download.tap()
        let deadline = Date.now.addingTimeInterval(120)
        while Date.now < deadline, download.label != "Downloaded" {
            idle(1)
        }
        XCTAssertEqual(download.label, "Downloaded", "Download did not complete")

        // Offline mode: the offline view lists the download; play it from there.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        waitFor(app.buttons["libraryPicker"]).tap()
        waitFor(button(containing: "Go Offline")).tap()
        waitFor(app.navigationBars["Offline"], timeout: 15, "Offline view not shown")
        waitFor(itemCell("The Time Machine"), timeout: 10, "Download missing in offline view").tap()
        startPlaybackAndOpenPlayer()
        XCTAssertTrue(waitForElapsed(atLeast: 6, timeout: 30), "Offline playback does not advance")
        app.buttons["player.playPause"].tap()
        idle(2)
        let localTime = elapsed()
        app.buttons["player.close"].tap()
        // Stopping finalizes the run: the local session becomes eligible for upload.
        waitFor(app.descendants(matching: .any)["miniPlayer"]).press(forDuration: 1.2)
        waitFor(button(containing: "Stop Playback"), timeout: 10).tap()

        // Nothing reached the server while offline.
        let offlineProgress = try await server.progress(itemID: itemID)
        XCTAssertNil(offlineProgress, "Progress was sent while offline")

        // Going online uploads the local session and progress.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        waitFor(button(containing: "Go Online"), timeout: 10).tap()
        waitForMainUI()

        let server = self.server!
        try await eventually(timeout: 40, "Offline progress not uploaded") {
            (try await server.progress(itemID: itemID)?.currentTime ?? 0) > 3
        }
        let uploaded = try await server.progress(itemID: itemID)
        XCTAssertGreaterThan(uploaded?.currentTime ?? 0, 3, "Uploaded progress \(String(describing: uploaded)) vs local elapsed \(localTime)")
        try await eventually(timeout: 40, "Offline listening session not uploaded") {
            try await server.sessions().contains { $0.libraryItemId == itemID && $0.updatedAt >= started && ($0.timeListening ?? 0) > 0 }
        }
    }

    func testServerProgressReachesApp() async throws {
        let title = "The Sign of the Four"
        let itemID = try await server.itemID(title: title)
        let duration = try await server.item(itemID).media.chapters?.last?.end ?? 0
        let server = self.server!
        func setPosition(_ seconds: Double) async throws {
            try await server.setProgress(itemID: itemID, body: ["currentTime": seconds, "duration": duration, "progress": seconds / duration, "isFinished": false])
        }
        try await server.resetItem(itemID)
        try await setPosition(1500)

        launchSignedIn()
        waitForMainUI()
        selectLibrary("Audiobooks")
        // Series books are grouped in the library grid; open the book from its series.
        selectTab("Series")
        waitFor(itemCell("Sherlock Holmes"), timeout: 30).tap()
        waitFor(button(containing: title), timeout: 20).tap()
        let play = waitFor(app.buttons["playButton"], timeout: 20)
        XCTAssertEqual(play.label, "Resume", "Server progress not shown on launch")
        let initial = play.value as? String ?? ""

        // Live update over Socket.IO while the detail is visible.
        try await setPosition(600)
        let live = NSPredicate(format: "value != %@", initial)
        let liveUpdated = XCTNSPredicateExpectation(predicate: live, object: play)
        await fulfillment(of: [liveUpdated], timeout: 20)
        let afterLive = play.value as? String ?? ""

        // Change while the app is in the background → picked up on foreground.
        XCUIDevice.shared.press(.home)
        try await setPosition(2400)
        try await Task.sleep(for: .seconds(2))
        app.activate()
        let foreground = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", afterLive), object: play)
        await fulfillment(of: [foreground], timeout: 25)

        // Pull to refresh on the detail.
        let afterForeground = play.value as? String ?? ""
        try await setPosition(1000)
        app.swipeDown(velocity: .fast)
        let refreshed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", afterForeground), object: play)
        await fulfillment(of: [refreshed], timeout: 25)

        // Resume starts from the server position (the player shows chapter-relative time).
        let chapters = try await server.item(itemID).media.chapters ?? []
        let chapterStart = chapters.last { $0.start <= 1000 }?.start ?? 0
        startPlaybackAndOpenPlayer()
        let position = elapsed()
        XCTAssertEqual(position, 1000 - chapterStart, accuracy: 8, "Resume did not start from server progress")
        app.buttons["player.playPause"].tap()
    }
}
