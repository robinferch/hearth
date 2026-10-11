#if DEBUG
import BackgroundTasks
import Foundation
import HearthAPI
import HearthData
import HearthModel
import OSLog

/// DEBUG-only: `-HearthDebugLogin <url> <user> <password>` signs in without UI (simulator checks, screenshots).
/// Skipped when the connection already exists. `-HearthDebugReindexSpotlight` forces a full Spotlight index.
/// `-HearthDebugSimulateSpotlightTask [expire]` launches the Spotlight `BGProcessingTask` the way the system does
/// (handler on a background queue), optionally expiring it after a few seconds.
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
        if let index = arguments.firstIndex(of: "-HearthDebugSimulateSpotlightTask") {
            simulateSpotlightTask(expire: arguments.count > index + 1 && arguments[index + 1] == "expire")
        }
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

    /// Uses the scheduler's private simulation hooks (the ones the debugger commands use).
    private static func simulateSpotlightTask(expire: Bool) {
        let identifier = SpotlightIndexer.taskIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hearth", category: "DebugLogin")
            let scheduler = BGTaskScheduler.shared
            let launch = NSSelectorFromString("_simulateLaunchForTaskWithIdentifier:")
            guard scheduler.responds(to: launch) else {
                logger.error("Simulating background tasks isn't available")
                return
            }
            logger.notice("Simulating the launch of \(identifier, privacy: .public)")
            _ = scheduler.perform(launch, with: identifier)
            guard expire else { return }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                logger.notice("Simulating the expiration of \(identifier, privacy: .public)")
                _ = BGTaskScheduler.shared.perform(NSSelectorFromString("_simulateExpirationForTaskWithIdentifier:"), with: identifier)
            }
        }
    }
}
#endif
