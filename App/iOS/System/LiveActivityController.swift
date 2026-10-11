import ActivityKit
import HearthData
import HearthIntents
import HearthModel
import HearthPlayback
import Observation
import OSLog

/// Mirrors the sleep timer into a Live Activity (Lock Screen + Dynamic Island).
///
/// - Starts when a timer is set (the app must be in the foreground; Siri-set timers in the background are skipped).
/// - Updates on play/pause, chapter changes and timer adjustments (observes `AudioPlayer`).
/// - After expiry the activity shows a "paused" state with a resume button for a few minutes, then ends.
/// - Stale activities from a previous run are ended at launch.
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    private typealias State = SleepTimerActivityAttributes.ContentState

    /// How long the expired ("paused") state stays visible.
    private static let expiredLifetime: TimeInterval = 10 * 60

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hearth", category: "LiveActivity")
    private var activity: Activity<SleepTimerActivityAttributes>?
    private var lastState: State?
    private var endTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var didStart = false

    private init() {}

    func start() {
        guard !didStart else { return }
        didStart = true
        endStaleActivities()
        observe()
        scheduleUpdate()
    }

    private func endStaleActivities() {
        for activity in Activity<SleepTimerActivityAttributes>.activities {
            // `Activity` isn't `Sendable`; its methods are safe to call from any context.
            nonisolated(unsafe) let activity = activity
            Task {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private func observe() {
        let player = AudioPlayer.shared
        withObservationTracking {
            _ = player.sleepTimer
            _ = player.sleepTimerExpiredAt
            _ = player.isPlaying
            _ = player.currentChapterIndex
            _ = player.playbackRate
            _ = player.currentItem?.id
        } onChange: {
            Task { @MainActor in
                LiveActivityController.shared.scheduleUpdate()
                LiveActivityController.shared.observe()
            }
        }
    }

    /// Coalesces bursts of changes (e.g. pause + timer shift).
    private func scheduleUpdate() {
        updateTask?.cancel()
        updateTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await update()
        }
    }

    private func update() async {
        let player = AudioPlayer.shared
        if let timer = player.sleepTimer, let item = player.currentItem {
            endTask?.cancel()
            endTask = nil
            let state = makeState(timer, player: player)
            if let activity, activity.attributes.itemID == item.id.description, activity.activityState == .active {
                await push(state, to: activity)
            } else {
                await end(immediately: true)
                await request(for: item, state: state)
            }
        } else if let activity, let expiredAt = player.sleepTimerExpiredAt, Date.now.timeIntervalSince(expiredAt) < Self.expiredLifetime, !player.isPlaying {
            var state = lastState ?? State(mode: .duration, isPlaying: false)
            state.isExpired = true
            state.isPlaying = false
            state.deadline = nil
            state.remaining = 0
            await push(state, to: activity)
            scheduleEnd(after: Self.expiredLifetime - Date.now.timeIntervalSince(expiredAt))
        } else {
            await end(immediately: true)
        }
    }

    private func makeState(_ timer: SleepTimerState, player: AudioPlayer) -> State {
        let chapterTitle = player.currentChapter?.title
        switch timer {
        case .duration(let deadline, _):
            let remaining = player.sleepTimerRemaining ?? max(0, deadline.timeIntervalSinceNow)
            return State(
                mode: .duration,
                deadline: player.isPlaying ? Date.now.addingTimeInterval(remaining) : nil,
                remaining: remaining,
                isPlaying: player.isPlaying,
                chapterTitle: chapterTitle
            )
        case .chapters(let remaining, _):
            let chapterEnd = player.isPlaying ? player.chapterRemainingTime.map { Date.now.addingTimeInterval($0) } : nil
            return State(mode: .chapters, chaptersRemaining: remaining, chapterEnd: chapterEnd, isPlaying: player.isPlaying, chapterTitle: chapterTitle)
        }
    }

    private func request(for item: AnyPlayableItem, state: State) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Self.logger.info("Live Activities are disabled")
            return
        }
        let snapshot = HearthData.shared.snapshot.snapshot
        let coverFile = snapshot.nowPlaying?.id == item.id ? snapshot.nowPlaying?.coverFile : nil
        let subtitle: String? = switch item {
        case .audiobook(let audiobook): audiobook.authorLine
        case .episode(let episode): episode.podcastName
        }
        let attributes = SleepTimerActivityAttributes(
            itemID: item.id.description,
            title: item.name,
            subtitle: subtitle,
            coverFile: coverFile,
            tint: AppSettings.shared.tintColor
        )
        do {
            activity = try Activity.request(attributes: attributes, content: content(state), pushType: nil)
            lastState = state
            Self.logger.info("Started sleep timer Live Activity")
        } catch {
            // Fails when the app is in the background (e.g. timer set through Siri).
            Self.logger.notice("Starting the Live Activity failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func push(_ state: State, to activity: Activity<SleepTimerActivityAttributes>) async {
        guard state != lastState else { return }
        lastState = state
        nonisolated(unsafe) let activity = activity
        await activity.update(content(state))
    }

    private func content(_ state: State) -> ActivityContent<State> {
        // Mark the content stale shortly after the timer should have fired, in case the app is suspended.
        let stale: Date? = if let deadline = state.deadline {
            deadline.addingTimeInterval(60)
        } else if state.isExpired {
            Date.now.addingTimeInterval(Self.expiredLifetime)
        } else {
            nil
        }
        return ActivityContent(state: state, staleDate: stale, relevanceScore: state.isPlaying ? 100 : 50)
    }

    private func scheduleEnd(after delay: TimeInterval) {
        guard endTask == nil else { return }
        endTask = Task {
            try? await Task.sleep(for: .seconds(max(1, delay)))
            guard !Task.isCancelled else { return }
            await self.end(immediately: true)
        }
    }

    private func end(immediately: Bool) async {
        guard let current = activity else { return }
        activity = nil
        lastState = nil
        nonisolated(unsafe) let ending = current
        await ending.end(nil, dismissalPolicy: immediately ? .immediate : .default)
        Self.logger.info("Ended sleep timer Live Activity")
    }
}
