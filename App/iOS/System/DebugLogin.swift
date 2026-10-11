#if DEBUG
import BackgroundTasks
import Foundation
import HearthAPI
import HearthData
import HearthModel
import OSLog

/// DEBUG-only: `-HearthDebugLogin <url> <user> <password>` signs in without UI (simulator checks, screenshots).
/// Skipped when the connection already exists. `-HearthDebugReset` first removes all connections (UI tests start from
/// a clean state; combined with `-HearthDebugLogin` only the debug connection remains).
/// `-HearthDebugReindexSpotlight` forces a full Spotlight index.
/// `-HearthDebugSimulateSpotlightTask [expire]` launches the Spotlight `BGProcessingTask` the way the system does
/// (handler on a background queue), optionally expiring it right after the launch.
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

    /// Device: the scheduler's private simulation hooks (the ones the debugger commands use). Simulator (no
    /// `BGTaskScheduler`): calls the registered launch handler and the expiration handler on background queues.
    private static func simulateSpotlightTask(expire: Bool) {
        let identifier = SpotlightIndexer.taskIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hearth", category: "DebugLogin")
            #if targetEnvironment(simulator)
            let taskClass: NSObject.Type = BGProcessingTask.self
            guard let task = taskClass.init() as? BGProcessingTask else { return }
            logger.notice("Calling the launch handler of \(identifier, privacy: .public) on a background queue")
            SpotlightIndexer.handleLaunch(task)
            guard expire else { return }
            nonisolated(unsafe) let expiring = task
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.05) {
                logger.notice("Calling the expiration handler of \(identifier, privacy: .public) on a background queue")
                expiring.expirationHandler?()
            }
            #else
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
            #endif
        }
    }
}
#endif
