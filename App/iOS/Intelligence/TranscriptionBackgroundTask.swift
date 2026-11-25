import BackgroundTasks
import HearthIntelligence
import HearthModel
import OSLog

/// Keeps a transcription running after the user leaves the app: every job gets a `BGContinuedProcessingTask`, whose
/// progress the system shows. When the system expires the task, the job is cancelled.
@MainActor
enum TranscriptionBackgroundTask {
    /// Matches `$(PRODUCT_BUNDLE_IDENTIFIER).transcription.*` in `BGTaskSchedulerPermittedIdentifiers`.
    private static let prefix = (Bundle.main.bundleIdentifier ?? "me.robinferch.hearth") + ".transcription"
    private nonisolated static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hearth", category: "TranscriptionBackgroundTask")

    static func start() {
        TranscriptionService.shared.jobStarted = { job in
            submit(itemID: job.id, title: job.title)
        }
    }

    #if DEBUG
    /// `-HearthDebugSimulateTranscriptionTask`: submits a task without a job, so the system launches the registered
    /// handler on its background queue (regression check for the build 7 crash).
    static func debugSubmit() {
        let id = ItemIdentifier(kind: .episode, connectionID: "debug", libraryID: "debug", primaryID: "debug", groupingID: "debug")
        submit(itemID: id, title: "Debug")
    }
    #endif

    private static func submit(itemID: ItemIdentifier, title: String) {
        let identifier = "\(prefix).\(UUID().uuidString)"
        guard register(identifier, itemID: itemID) else {
            logger.error("Registering the transcription task failed")
            return
        }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: String(localized: "Creating Transcript", table: "Intelligence"),
            subtitle: title
        )
        // Without room for the task the job simply runs while the app is open.
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger.notice("The transcription can't continue in the background: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Registers the launch handler. Continued processing tasks may be registered at any time (not only during launch).
    ///
    /// `BGTaskScheduler` calls the handler on a background queue, so the closure must not be isolated to the main actor:
    /// one written in a main-actor function would be, and Swift 6 traps on its isolation check (TestFlight crash,
    /// build 7). Creating it in this nonisolated function keeps it free of actor isolation.
    private nonisolated static func register(_ identifier: String, itemID: ItemIdentifier) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            handle(task, itemID: itemID)
        }
    }

    /// Called by `BGTaskScheduler` on a background queue.
    private nonisolated static func handle(_ task: BGTask, itemID: ItemIdentifier) {
        guard let task = task as? BGContinuedProcessingTask else {
            task.setTaskCompleted(success: false)
            return
        }
        logger.notice("Transcription task launched")
        nonisolated(unsafe) let continued = task
        continued.progress.totalUnitCount = 1000
        let monitor = Task { @MainActor in
            let service = TranscriptionService.shared
            while !Task.isCancelled, let job = service.job(for: itemID), job.phase.isRunning {
                continued.progress.completedUnitCount = Int64(job.overallProgress * 1000)
                if let remaining = job.remaining, remaining > 0 {
                    continued.updateTitle(continued.title, subtitle: String(localized: "\(job.title) · \(IntelligenceFormat.approximate(remaining)) left", table: "Intelligence"))
                }
                try? await Task.sleep(for: .seconds(1))
            }
            // Expired: the expiration handler already completed the task.
            guard !Task.isCancelled else { return }
            continued.progress.completedUnitCount = 1000
            continued.setTaskCompleted(success: service.job(for: itemID)?.phase == .finished)
            logger.notice("Transcription task completed")
        }
        continued.expirationHandler = {
            logger.notice("The system ended the transcription task")
            monitor.cancel()
            Task { @MainActor in
                TranscriptionService.shared.cancel(itemID)
            }
            continued.setTaskCompleted(success: false)
        }
    }
}
