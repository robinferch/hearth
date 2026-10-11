// CONTRACT FILE – public surface of HearthPlayback.
// Implementations live in the `AudioPlayer+*.swift` extensions; this file holds the state and the
// public entry points. Public names/signatures are stable (adding members/default parameters is fine).

import AVFoundation
import Foundation
import HearthData
import HearthModel
import Observation
import os

public enum PlaybackError: Error, Sendable {
    case notPlayable
    case downloadInProgress
    case noPlaybackItem
    case startFailed(String)
}

extension PlaybackError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notPlayable: String(localized: "This item can't be played.", bundle: .module)
        case .downloadInProgress: String(localized: "This item is currently downloading.", bundle: .module)
        case .noPlaybackItem: String(localized: "Nothing is playing.", bundle: .module)
        case .startFailed(let reason): String(localized: "Playback couldn't be started: \(reason)", bundle: .module)
        }
    }
}

/// The single, app-wide audio player.
@MainActor
@Observable
public final class AudioPlayer {
    public static let shared = AudioPlayer()

    init() {}

    // MARK: State

    public internal(set) var currentItem: AnyPlayableItem?
    public internal(set) var origin: PlaybackOrigin = .none
    public internal(set) var isPlaying = false
    public internal(set) var isBuffering = false
    /// True while starting or seeking.
    public internal(set) var isBusy = false

    /// Absolute position in the item.
    public internal(set) var currentTime: TimeInterval = 0
    public internal(set) var duration: TimeInterval = 0

    public internal(set) var chapters: [Chapter] = []
    public internal(set) var currentChapterIndex: Int?
    public var currentChapter: Chapter? { currentChapterIndex.flatMap { chapters.indices.contains($0) ? chapters[$0] : nil } }

    /// Position/length used by scrubbers: chapter-relative when enabled & available, else whole item.
    public internal(set) var displayedTime: TimeInterval = 0
    public internal(set) var displayedDuration: TimeInterval = 0

    public internal(set) var playbackRate: Double = 1

    /// User queue (play next / add to queue).
    public internal(set) var queue: [AnyPlayableItem] = []
    /// Generated Up Next.
    public internal(set) var upNext: [AnyPlayableItem] = []
    /// Localized description of the Up Next source ("Series: Foo").
    public internal(set) var upNextSource: String?

    public internal(set) var sleepTimer: SleepTimerState?
    /// Remaining seconds of a duration sleep timer (updated every second while active).
    public internal(set) var sleepTimerRemaining: TimeInterval?

    public internal(set) var route: AudioRoute = .speaker

    /// Last played item when idle (for the "Resume" pill).
    public internal(set) var lastPlayedItemID: ItemIdentifier?

    /// Set when a new item started (UI may auto-open the full player).
    public internal(set) var startedItemAt: Date?

    // MARK: Additional state (Hearth additions)

    /// Last playback failure (start failed, stream broke). Cleared on the next successful start.
    public internal(set) var lastError: PlaybackError?
    /// When the sleep timer last expired (Live Activity "paused" state, play-to-extend window).
    public internal(set) var sleepTimerExpiredAt: Date?
    /// Running total while skip taps are being combined (badge), `nil` when idle.
    public internal(set) var pendingSkipTotal: TimeInterval?
    /// Whether the current item is played from local files.
    public internal(set) var isPlayingLocalFiles = false

    /// Whether an item is loaded (playing or paused).
    public var isActive: Bool { currentItem != nil }
    /// Remaining real time of the item at the current rate.
    public var remainingTime: TimeInterval { max(0, duration - currentTime) / max(playbackRate, 0.01) }
    /// Remaining real time of the current chapter at the current rate.
    public var chapterRemainingTime: TimeInterval? {
        guard let currentChapter else { return nil }
        return max(0, currentChapter.end - currentTime) / max(playbackRate, 0.01)
    }
    /// Bookmarks are supported for audiobooks only.
    public var canCreateBookmark: Bool {
        if case .audiobook = currentItem { true } else { false }
    }

    // MARK: Internal engine state

    @ObservationIgnored let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.hearth", category: "AudioPlayer")
    @ObservationIgnored var didSetup = false
    @ObservationIgnored var player: AVQueuePlayer?
    @ObservationIgnored var timeObserver: Any?
    @ObservationIgnored var keyValueObservations: [NSKeyValueObservation] = []
    @ObservationIgnored var notificationTokens: [any NSObjectProtocol] = []
    /// Observers tied to the current `AVQueuePlayer` (removed when the player is recreated).
    @ObservationIgnored var playerNotificationTokens: [any NSObjectProtocol] = []

    /// Identifies the active playback run; async work from stale runs is discarded.
    @ObservationIgnored var runID = UUID()
    @ObservationIgnored var timeline = PlaybackTimeline.empty
    @ObservationIgnored var loadedTracks: [LoadedTrack] = []
    /// Status observations of the loaded player items (failure detection).
    @ObservationIgnored var itemStatusObservations: [NSKeyValueObservation] = []
    @ObservationIgnored var streamingHeaders: [String: String] = [:]
    @ObservationIgnored var reporter: SessionReporter?
    @ObservationIgnored var busyCount = 0 {
        didSet { isBusy = busyCount > 0 }
    }
    /// The user wants audio to play (as opposed to the player's actual state).
    @ObservationIgnored var intendsToPlay = false
    @ObservationIgnored var lastPauseDate: Date?
    @ObservationIgnored var resumeAfterInterruption = false
    /// When the system paused playback we intended to play (interruption, failed stream). Lets a late
    /// interruption notification / stream recovery know that audio was playing.
    @ObservationIgnored var systemPausedAt: Date?
    /// The start in progress (`startPlayback`) and whether the user paused while it was starting.
    @ObservationIgnored var startingRunID: UUID?
    @ObservationIgnored var pausedDuringStart = false
    /// Whether listening time and the sleep timer are counting (stops during long stalls while `isPlaying` stays on).
    @ObservationIgnored var isListeningClockRunning = false
    @ObservationIgnored var stallTask: Task<Void, Never>?
    /// Last automatic stream recovery (rebuild with fresh headers); one retry per minute.
    @ObservationIgnored var lastStreamRecovery: Date?
    /// Last recovery from a rejected stream token (401/403): token refresh + rebuild.
    @ObservationIgnored var lastAuthRecovery: Date?
    @ObservationIgnored var isRecoveringStream = false
    @ObservationIgnored var upNextGenerationDisabled = false
    /// Run whose finish flow is in progress (guards against double handling).
    @ObservationIgnored var finishingRunID: UUID?
    @ObservationIgnored var queueRestored = false

    @ObservationIgnored var sleepTimerTask: Task<Void, Never>?
    @ObservationIgnored var chapterSleepTask: Task<Void, Never>?
    @ObservationIgnored var sleepTimerPausedAt: Date?
    @ObservationIgnored var lastExpiredSleepTimer: SleepTimerState?
    @ObservationIgnored var isFading = false

    @ObservationIgnored var skipCombiner = SkipTapCombiner()
    @ObservationIgnored var skipCombinerTask: Task<Void, Never>?

    @ObservationIgnored var lastSnapshotUpdate = Date.distantPast
    @ObservationIgnored var snapshotCoverFile: String?
    @ObservationIgnored var nowPlayingInfo: [String: Any] = [:]
    @ObservationIgnored var artworkItemID: ItemIdentifier?
    @ObservationIgnored var artworkTask: Task<Void, Never>?
    @ObservationIgnored var nowPlayingArtwork: AnyObject?

    // MARK: Lifecycle

    /// Configures audio session, remote commands and restores the queue. Call once at launch.
    public func setup() {
        performSetup()
    }

    // MARK: Starting playback

    /// Starts an item. If it is already the current item, toggles play/pause instead.
    public func play(_ id: ItemIdentifier, origin: PlaybackOrigin = .none, at time: TimeInterval? = nil) async throws {
        if isCurrent(id) {
            if let time {
                await seek(to: time)
                lastPauseDate = nil
                resume()
            } else {
                togglePlayPause()
            }
            return
        }
        try await startPlayback(id, origin: origin, at: time, resetUpNext: true)
    }

    /// Starts the first eligible item of a series, podcast or collection.
    public func play(grouping id: ItemIdentifier) async throws {
        let item: AnyPlayableItem
        do {
            item = try await HearthData.shared.items.firstPlayable(in: id)
        } catch {
            throw PlaybackError.noPlaybackItem
        }
        let origin: PlaybackOrigin = switch id.kind {
        case .series: .series(id)
        case .podcast: .podcast(id)
        case .collection, .playlist: .collection(id)
        default: .none
        }
        try await play(item.id, origin: origin)
    }

    /// Resumes the last played item.
    public func resumeLastPlayed() async throws {
        guard let lastPlayedItemID else { throw PlaybackError.noPlaybackItem }
        if isCurrent(lastPlayedItemID) {
            resume()
            return
        }
        try await performResumeLastPlayed(lastPlayedItemID)
    }

    // MARK: Transport

    public func resume() { performResume() }
    public func pause() { performPause() }
    public func togglePlayPause() {
        if isPlaying || (intendsToPlay && isBuffering) || willPlayAfterStart {
            pause()
        } else {
            resume()
        }
    }
    public func stop() async { await performStop() }

    /// Absolute seek.
    public func seek(to time: TimeInterval) async { await seekInternal(to: time) }
    /// Seek relative to the active chapter start (scrubber).
    public func seek(toDisplayedTime time: TimeInterval) async {
        await seekInternal(to: absoluteTime(forDisplayedTime: time))
    }
    public func skipForward(_ seconds: TimeInterval? = nil) async {
        await seekInternal(to: currentTime + (seconds ?? TimeInterval(AppSettings.shared.skipForwardInterval)))
    }
    public func skipBackward(_ seconds: TimeInterval? = nil) async {
        await seekInternal(to: max(0, currentTime - (seconds ?? TimeInterval(AppSettings.shared.skipBackwardInterval))))
    }
    public func nextChapter() async { await performNextChapter() }
    /// Goes to the start of the chapter, or the previous chapter when within the first 3 s.
    public func previousChapter() async { await performPreviousChapter() }
    public func seek(toChapter chapter: Chapter) async { await seekInternal(to: chapter.start) }

    public func setPlaybackRate(_ rate: Double) { applyPlaybackRate(rate, save: true) }
    /// Next preset (wraps).
    public func cyclePlaybackRate() {
        setPlaybackRate(PlaybackRateMath.next(after: playbackRate, presets: AppSettings.shared.playbackRatePresets))
    }

    // MARK: Queue

    public func playNext(_ id: ItemIdentifier) async throws { try await enqueue(id, atFront: true) }
    public func addToQueue(_ id: ItemIdentifier) async throws { try await enqueue(id, atFront: false) }
    public func addToQueue(_ ids: [ItemIdentifier]) async { await enqueue(ids) }
    public func moveQueueItems(from source: IndexSet, to destination: Int) {
        queue = QueueLogic.moved(queue, from: source, to: destination)
        queueDidChange()
    }
    public func removeFromQueue(at offsets: IndexSet) {
        queue = QueueLogic.removed(queue, at: offsets)
        queueDidChange()
    }
    public func removeFromUpNext(at offsets: IndexSet) {
        upNext = QueueLogic.removed(upNext, at: offsets)
        if upNext.isEmpty {
            upNextGenerationDisabled = true
            upNextSource = nil
        }
        queueDidChange()
    }
    public func clearQueue() {
        queue = []
        queueDidChange()
    }
    public func clearUpNext() {
        upNext = []
        upNextSource = nil
        upNextGenerationDisabled = true
        queueDidChange()
    }
    public func promoteUpNextItem(at index: Int) {
        guard upNext.indices.contains(index) else { return }
        let item = upNext.remove(at: index)
        queue = QueueLogic.appending(item, to: queue)
        queueDidChange()
    }
    public func jumpToQueueItem(at index: Int) async { await performJumpToQueueItem(at: index) }
    public func jumpToUpNextItem(at index: Int) async { await performJumpToUpNextItem(at: index) }
    /// Skips to the next queue/up next item.
    public func advance() async { await performAdvance() }

    // MARK: Sleep timer

    public func setSleepTimer(_ preset: SleepTimerPreset) { applySleepTimer(SleepTimerMath.state(for: preset, now: .now)) }
    /// Sleep at the end of the given chapter.
    public func setSleepTimer(endOf chapter: Chapter) { performSetSleepTimer(endOf: chapter) }
    public func extendSleepTimer() { performExtendSleepTimer() }
    /// ±1 minute or ±1 chapter; cancels when going below the minimum.
    public func adjustSleepTimer(by delta: Int) { performAdjustSleepTimer(by: delta) }
    public func cancelSleepTimer() { performCancelSleepTimer() }
    /// Call from a `motionEnded(.motionShake)` handler; extends the timer when `shakeExtendsSleepTimer` is on.
    public func handleShake() { performHandleShake() }

    // MARK: Bookmarks

    /// Creates a bookmark at the current position. `nil` note = quick bookmark (formatted date).
    @discardableResult
    public func createBookmark(note: String? = nil) async throws -> Bookmark {
        try await performCreateBookmark(note: note)
    }

    // MARK: Item state hooks

    /// Marks the current item finished (seeks to end → normal finish flow), or forwards to ProgressStore.
    public func setFinished(_ id: ItemIdentifier, finished: Bool) async throws {
        try await performSetFinished(id, finished: finished)
    }

    /// Whether `id` is the current item.
    public func isCurrent(_ id: ItemIdentifier) -> Bool { currentItem?.id == id }
}

/// A player item enqueued in the `AVQueuePlayer` and the timeline track it plays.
struct LoadedTrack {
    let item: AVPlayerItem
    let position: Int
}
