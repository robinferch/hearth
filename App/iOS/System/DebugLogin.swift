#if DEBUG
import Foundation
import HearthAPI
import HearthData
import HearthModel
import OSLog

/// DEBUG-only: `-HearthDebugLogin <url> <user> <password>` signs in without UI (simulator checks, screenshots).
/// Skipped when the connection already exists. `-HearthDebugReset` first removes all connections (UI tests start from
/// a clean state; combined with `-HearthDebugLogin` only the debug connection remains).
/// `-HearthDebugReindexSpotlight` forces a full Spotlight index.
@MainActor
enum DebugLogin {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hearth", category: "DebugLogin")

    static func runIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-HearthDebugReindexSpotlight") {
            // Forces a full Spotlight index after bootstrap.
            Task {
                await HearthData.shared.bootstrap()
                await SpotlightIndexer.shared.indexAll()
            }
        }
        let resets = arguments.contains("-HearthDebugReset")
        let login = arguments.firstIndex(of: "-HearthDebugLogin").flatMap { index -> (host: URL, username: String, password: String)? in
            guard arguments.count > index + 3, let host = Connection.normalizedHost(arguments[index + 1]) else { return nil }
            return (host, arguments[index + 2], arguments[index + 3])
        }
        guard resets || login != nil else { return }
        let connections = HearthData.shared.connections
        Task {
            if resets {
                await connections.removeAll()
                logger.notice("Debug reset: removed all connections")
            }
            guard case let (host, username, password)? = login else { return }
            guard connections.connection(Connection.makeID(host: host, username: username)) == nil else {
                logger.info("Debug login: connection exists")
                return
            }
            do {
                let status = try await ServerAuthenticator.status(host: host, headers: [])
                let result = try await ServerAuthenticator.login(host: host, headers: [], username: username, password: password)
                let connection = Connection(host: host, username: result.username, userID: result.userID, serverVersion: status.serverVersion)
                await connections.add(connection, tokens: result.tokens)
                logger.notice("Debug login succeeded for \(connection.displayName, privacy: .public)")
                await HearthData.shared.refresh()
                await SpotlightIndexer.shared.launchUpdate()
            } catch {
                logger.error("Debug login failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
#endif
