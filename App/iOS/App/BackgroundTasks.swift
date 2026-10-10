import BackgroundTasks
import HearthData
import OSLog

/// BGTaskScheduler identifiers and handlers (registered through SwiftUI's `.backgroundTask`).
enum BackgroundTaskScheduler {
    private static let bundleID = Bundle.main.bundleIdentifier ?? "dev.hearth.hearth"
    /// App refresh every ≥ 3 h: evaluates automatic download rules.
    static let autoDownloadIdentifier = bundleID + ".autodownload"
    /// App refresh: progress / bookmark sync and pending session upload.
    static let syncIdentifier = bundleID + ".sync"

    private static let logger = Logger(subsystem: bundleID, category: "BackgroundTasks")

    static func scheduleAll() {
        schedule(autoDownloadIdentifier, after: 3 * 3600)
        schedule(syncIdentifier, after: 3600)
    }

    private static func schedule(_ identifier: String, after interval: TimeInterval) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger.notice("Could not schedule \(identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    @MainActor
    static func runAutoDownloads() async {
        schedule(autoDownloadIdentifier, after: 3 * 3600)
        let data = HearthData.shared
        if !AppEvents.shared.bootstrapFinished {
            await data.bootstrap()
            AppEvents.shared.bootstrapFinished = true
        }
        guard data.settings.autoDownloadsEnabled else { return }
        await data.downloads.runAutoDownloads()
        logger.info("Background auto-download run finished")
    }

    @MainActor
    static func runSync() async {
        schedule(syncIdentifier, after: 3600)
        let data = HearthData.shared
        if !AppEvents.shared.bootstrapFinished {
            await data.bootstrap()
            AppEvents.shared.bootstrapFinished = true
        }
        await data.listening.uploadPendingSessions()
        await data.progress.sync()
        await data.bookmarks.sync()
        logger.info("Background sync finished")
    }
}
