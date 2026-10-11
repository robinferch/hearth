#if DEBUG
import HearthAPI
import HearthData
import HearthModel
import HearthPlayback
import OSLog
import SwiftUI

/// DEBUG-only launch helpers for UI checks without driving the onboarding UI.
///
/// `-HearthDebugLogin "http://localhost:13378 root hearth"` signs in and adds the connection at launch (skipped when
/// it already exists).
@MainActor
enum DebugSupport {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hearth", category: "DebugSupport")
    private static var didRun = false

    /// `-HearthDebugPlayerPanel chapters|queue` opens the full player with the panel showing.
    static var initialPlayerPanel: String? { UserDefaults.standard.string(forKey: "HearthDebugPlayerPanel") }
    /// `-HearthDebugExpandSections YES` expands the collapsible detail sections.
    static var expandsSections: Bool { UserDefaults.standard.bool(forKey: "HearthDebugExpandSections") }

    static func performLaunchActions() async {
        guard !didRun else { return }
        didRun = true
        await login()
        await performNavigation()
    }

    /// `-HearthDebugOpen <identifier>`, `-HearthDebugPlay <identifier>` (+ `-HearthDebugQueue "<id>,<id>"`).
    private static func performNavigation() async {
        let defaults = UserDefaults.standard
        let open = defaults.string(forKey: "HearthDebugOpen").flatMap(ItemIdentifier.init)
        let play = defaults.string(forKey: "HearthDebugPlay").flatMap(ItemIdentifier.init)
        guard open != nil || play != nil else { return }
        let connections = HearthData.shared.connections
        for _ in 0..<150 where !(AppEvents.shared.bootstrapFinished && !connections.allLibraries.isEmpty) {
            try? await Task.sleep(for: .milliseconds(200))
        }
        try? await Task.sleep(for: .seconds(1))
        if let open {
            AppEvents.shared.post(.open(open))
        }
        if let play {
            try? await Task.sleep(for: .seconds(1))
            AppEvents.shared.post(.play(play))
            let queue = (defaults.string(forKey: "HearthDebugQueue") ?? "").split(separator: ",").compactMap { ItemIdentifier(String($0)) }
            if !queue.isEmpty {
                try? await Task.sleep(for: .seconds(4))
                await AudioPlayer.shared.addToQueue(queue)
            }
        }
    }

    private static func login() async {
        guard let value = UserDefaults.standard.string(forKey: "HearthDebugLogin") else { return }
        let parts = value.split(separator: " ").map(String.init)
        guard parts.count == 3, let host = Connection.normalizedHost(parts[0]) else {
            logger.error("Invalid -HearthDebugLogin value")
            return
        }
        let connections = HearthData.shared.connections
        while !connections.isLoaded {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let id = Connection.makeID(host: host, username: parts[1])
        guard connections.connection(id) == nil else {
            logger.info("Debug connection \(id, privacy: .public) already exists")
            return
        }
        do {
            let status = try await ServerAuthenticator.status(host: host, headers: [])
            let result = try await ServerAuthenticator.login(host: host, headers: [], username: parts[1], password: parts[2])
            let connection = Connection(host: host, username: result.username, userID: result.userID, headers: [], serverVersion: status.serverVersion)
            await connections.add(connection, tokens: result.tokens)
            logger.info("Added debug connection \(connection.id, privacy: .public)")
        } catch {
            logger.error("Debug login failed: \(String(describing: error), privacy: .public)")
        }
    }
}
#endif
