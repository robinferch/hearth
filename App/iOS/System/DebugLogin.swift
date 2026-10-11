#if DEBUG
import Foundation
import HearthAPI
import HearthData
import HearthModel
import OSLog

/// DEBUG-only: `-HearthDebugLogin <url> <user> <password>` signs in without UI (simulator checks, screenshots).
/// Skipped when the connection already exists.
@MainActor
enum DebugLogin {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hearth", category: "DebugLogin")

    static func runIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-HearthDebugLogin"), arguments.count > index + 3,
              let host = Connection.normalizedHost(arguments[index + 1]) else { return }
        let username = arguments[index + 2]
        let password = arguments[index + 3]
        let connections = HearthData.shared.connections
        guard connections.connection(Connection.makeID(host: host, username: username)) == nil else {
            logger.info("Debug login: connection exists")
            return
        }
        Task {
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
