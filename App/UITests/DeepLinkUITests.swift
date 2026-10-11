import CryptoKit
import XCTest

/// `hearth://` URLs used by widgets, complications, Spotlight and Shortcuts.
final class DeepLinkUITests: HearthUITestCase {
    /// Same derivation as `Connection.makeID(host:username:)`.
    private func connectionID() -> String {
        let digest = SHA256.hash(data: Data("host:\(Self.server).user:\(Self.username)".utf8))
        return String(Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            .prefix(22))
    }

    func testDeepLinks() async throws {
        let frankenstein = try await server.items()["Frankenstein"]
        let item = try XCTUnwrap(frankenstein)
        let identifier = "audiobook::\(connectionID())::\(item.libraryId)::\(item.id)"

        launchSignedIn()
        waitForMainUI()

        app.open(URL(string: "hearth://item/\(identifier)")!)
        waitFor(app.buttons["playButton"], timeout: 20, "hearth://item did not open the audiobook")
        XCTAssertTrue(element(containing: "Mary Shelley").exists)

        app.open(URL(string: "hearth://search?q=emma")!)
        XCTAssertEqual(waitFor(app.searchFields.firstMatch).value as? String, "emma")
        XCTAssertTrue(element(containing: "Emma").waitForExistence(timeout: 20), "Search results missing")

        app.open(URL(string: "hearth://statistics")!)
        waitFor(app.navigationBars["Statistics"], timeout: 15, "hearth://statistics did not open statistics")

        app.open(URL(string: "hearth://listen-now")!)
        waitFor(app.navigationBars["Listen Now"], timeout: 15, "hearth://listen-now did not open Listen Now")
        app.swipeDown(velocity: .fast)

        // Something to show in the player: Frankenstein was last played (or starts now).
        app.open(URL(string: "hearth://play/\(identifier)")!)
        let close = app.buttons["player.close"]
        if close.waitForExistence(timeout: 15) {
            app.buttons["player.playPause"].tap()
            close.tap()
        }
        app.open(URL(string: "hearth://nowplaying")!)
        waitFor(close, timeout: 15, "hearth://nowplaying did not open the player")
        close.tap()
    }
}
