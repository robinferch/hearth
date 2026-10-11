import ActivityKit
import HearthData
import HearthIntents
import HearthModel
import HearthPlayback
import Observation
import OSLog
import UIKit

/// Mirrors the sleep timer into a Live Activity (Lock Screen + Dynamic Island).
///
/// - Starts when a timer is set. Activities can only be requested while the app is in the foreground or from a
///   `LiveActivityIntent` (Siri, Shortcuts, Control Center: the timer intents call `updateNow()` from `perform`).
///   A request that failed in the background (e.g. a timer set on the watch) is retried when the app becomes active.
/// - Updates on play/pause, seeks, chapter and item changes and timer adjustments (observes `AudioPlayer`). The current
///   item is part of the content state, so auto-advance updates the activity instead of requesting a new one
///   (which would fail while the device is locked).
/// - After expiry the activity shows a "paused" state with a resume button. It is ended right away with a dismissal
///   date, so the system removes it after a few minutes even when the app is suspended by then.
/// - Stale activities from a previous run are ended at launch.
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    private typealias State = SleepTimerActivityAttributes.ContentState

    /// How long the expired ("paused") state stays visible.
    private static let expiredLifetime: TimeInterval = 10 * 60
    /// Delay before re-checking for a cover that the player is still writing to the snapshot.
    private static let coverRetryDelay: Duration = .seconds(3)

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hearth", category: "LiveActivity")
    private var activity: Activity<SleepTimerActivityAttributes>?
    private var lastState: State?
    /// The activity was ended with a delayed dismissal (expired state); it can't be updated anymore.
    private var isEndedExpired = false
    private var updateTask: Task<Void, Never>?
    private var updateChain: Task<Void, Never>?
    private var coverRetryItemID: ItemIdentifier?
    private var tokens: [any NSObjectProtocol] = []
    private var didStart = false

    private init() {}

    func start() {
        guard !didStart else { return }
        didStart = true
        endStaleActivities()
        observe()

        let center = NotificationCenter.default
        // Seeks move the end of the chapter that chapter timers count down to.
        tokens.append(center.addObserver(forName: AudioPlayer.positionChangedNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                LiveActivityController.shared.scheduleUpdate()
            }
        })
        // Requests fail in the background: retry once the app is in the foreground.
        tokens.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                LiveActivityController.shared.scheduleUpdate()
            }
        })
        SleepTimerActions.liveActivityUpdater = {
            await LiveActivityController.shared.updateNow()
        }
        scheduleUpdate()
    }

    /// Brings the activity up to date immediately (called from timer intents while they may start activities).
    func updateNow() async {
        updateTask?.cancel()
        updateTask = nil
        await enqueueUpdate()
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
            await enqueueUpdate()
        }
    }

    /// Runs updates one after another: they await ActivityKit and must not interleave (double requests).
    private func enqueueUpdate() async {
        let previous = updateChain
        let task = Task {
            await previous?.value
            await update()
        }
        updateChain = task
        await task.value
    }

    private func update() async {
        let player = AudioPlayer.shared
        if let timer = player.sleepTimer, let item = player.currentItem {
            let state = makeState(timer, item: item, player: player)
            if let activity, !isEndedExpired, activity.activityState == .active {
                await push(state, to: activity)
            } else {
                await endActivity()
                request(for: item, state: state)
            }
            retryCoverIfNeeded(state, itemID: item.id)
        } else if let activity, let expiredAt = player.sleepTimerExpiredAt, Date.now.timeIntervalSince(expiredAt) < Self.expiredLifetime, !player.isPlaying {
            guard !isEndedExpired else { return }
            var state = lastState ?? State(mode: .duration, isPlaying: false)
            state.isExpired = true
            state.isPlaying = false
            state.deadline = nil
            state.chapterEnd = nil
            state.remaining = 0
            isEndedExpired = true
            lastState = state
            nonisolated(unsafe) let ending = activity
            await ending.end(content(state), dismissalPolicy: .after(expiredAt.addingTimeInterval(Self.expiredLifetime)))
            Self.logger.info("Ended sleep timer Live Activity (expired)")
        } else {
            await endActivity()
        }
    }

    private func makeState(_ timer: SleepTimerState, item: AnyPlayableItem, player: AudioPlayer) -> State {
        let chapterTitle = player.currentChapter?.title
        var state: State
        switch timer {
        case .duration(let deadline, _):
            let remaining = player.sleepTimerRemaining ?? max(0, deadline.timeIntervalSinceNow)
            state = State(
                mode: .duration,
                deadline: player.isPlaying ? Date.now.addingTimeInterval(remaining) : nil,
                remaining: remaining,
                isPlaying: player.isPlaying,
                chapterTitle: chapterTitle
            )
        case .chapters(let remaining, _):
            let chapterEnd = player.isPlaying ? player.chapterRemainingTime.map { Date.now.addingTimeInterval($0) } : nil
            state = State(mode: .chapters, chaptersRemaining: remaining, chapterEnd: chapterEnd, isPlaying: player.isPlaying, chapterTitle: chapterTitle)
        }
        let snapshot = HearthData.shared.snapshot.snapshot
        state.itemID = item.id.description
        state.title = item.name
        state.subtitle = Self.subtitle(of: item)
        state.coverFile = snapshot.nowPlaying?.id == item.id ? snapshot.nowPlaying?.coverFile : nil
        return state
    }

    private static func subtitle(of item: AnyPlayableItem) -> String? {
        switch item {
        case .audiobook(let audiobook): audiobook.authorLine
        case .episode(let episode): episode.podcastName
        }
    }

    /// The player writes the cover to the snapshot shortly after an item starts; pick it up once it's there.
    private func retryCoverIfNeeded(_ state: State, itemID: ItemIdentifier) {
        guard state.coverFile == nil, coverRetryItemID != itemID else { return }
        coverRetryItemID = itemID
        Task {
            try? await Task.sleep(for: Self.coverRetryDelay)
            scheduleUpdate()
        }
    }

    private func request(for item: AnyPlayableItem, state: State) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Self.logger.info("Live Activities are disabled")
            return
        }
        let attributes = SleepTimerActivityAttributes(
            itemID: item.id.description,
            title: item.name,
            subtitle: state.subtitle,
            coverFile: state.coverFile,
            tint: AppSettings.shared.tintColor
        )
        do {
            activity = try Activity.request(attributes: attributes, content: content(state), pushType: nil)
            lastState = state
            isEndedExpired = false
            Self.logger.info("Started sleep timer Live Activity")
        } catch {
            // Fails in the background outside a Live Activity intent; retried when the app becomes active.
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

    private func endActivity() async {
        guard let current = activity else { return }
        activity = nil
        lastState = nil
        isEndedExpired = false
        nonisolated(unsafe) let ending = current
        await ending.end(nil, dismissalPolicy: .immediate)
        Self.logger.info("Ended sleep timer Live Activity")
    }
}
