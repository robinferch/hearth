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
            submit(for: job)
        }
    }

    private static func submit(for job: TranscriptionService.Job) {
        let identifier = "\(prefix).\(UUID().uuidString)"
        let itemID = job.id
        // Continued processing tasks may be registered at any time (not only during launch).
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            handle(task, itemID: itemID)
        }
        guard registered else {
            logger.error("Registering the transcription task failed")
            return
        }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: String(localized: "Creating Transcript", table: "Intelligence"),
            subtitle: job.title
        )
        // Without room for the task the job simply runs while the app is open.
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger.notice("The transcription can't continue in the background: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Called by `BGTaskScheduler` on a background queue.
    private nonisolated static func handle(_ task: BGTask, itemID: ItemIdentifier) {
        guard let task = task as? BGContinuedProcessingTask else {
            task.setTaskCompleted(success: false)
            return
        }
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
