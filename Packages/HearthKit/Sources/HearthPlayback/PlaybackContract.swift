// CONTRACT FILE – public surface of HearthPlayback.
// The bodies here are TEMPORARY STUBS. The HearthPlayback implementer replaces them (and may split
// the type into multiple files/extensions), but must keep these public names and signatures source
// compatible. Adding members or default parameters is fine.

import Foundation
import HearthData
import HearthModel
import Observation

public enum PlaybackError: Error, Sendable {
    case notPlayable
    case downloadInProgress
    case noPlaybackItem
    case startFailed(String)
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

    // MARK: Lifecycle

    /// Configures audio session, remote commands and restores the queue. Call once at launch.
    public func setup() {}

    // MARK: Starting playback

    /// Starts an item. If it is already the current item, toggles play/pause instead.
    public func play(_ id: ItemIdentifier, origin: PlaybackOrigin = .none, at time: TimeInterval? = nil) async throws {}

    /// Starts the first eligible item of a series, podcast or collection.
    public func play(grouping id: ItemIdentifier) async throws {}

    /// Resumes the last played item.
    public func resumeLastPlayed() async throws {}

    // MARK: Transport

    public func resume() {}
    public func pause() {}
    public func togglePlayPause() {}
    public func stop() async {}

    /// Absolute seek.
    public func seek(to time: TimeInterval) async {}
    /// Seek relative to the active chapter start (scrubber).
    public func seek(toDisplayedTime time: TimeInterval) async {}
    public func skipForward(_ seconds: TimeInterval? = nil) async {}
    public func skipBackward(_ seconds: TimeInterval? = nil) async {}
    public func nextChapter() async {}
    /// Goes to the start of the chapter, or the previous chapter when within the first 3 s.
    public func previousChapter() async {}
    public func seek(toChapter chapter: Chapter) async {}

    public func setPlaybackRate(_ rate: Double) {}
    /// Next preset (wraps).
    public func cyclePlaybackRate() {}

    // MARK: Queue

    public func playNext(_ id: ItemIdentifier) async throws {}
    public func addToQueue(_ id: ItemIdentifier) async throws {}
    public func addToQueue(_ ids: [ItemIdentifier]) async {}
    public func moveQueueItems(from source: IndexSet, to destination: Int) {}
    public func removeFromQueue(at offsets: IndexSet) {}
    public func removeFromUpNext(at offsets: IndexSet) {}
    public func clearQueue() {}
    public func clearUpNext() {}
    public func promoteUpNextItem(at index: Int) {}
    public func jumpToQueueItem(at index: Int) async {}
    public func jumpToUpNextItem(at index: Int) async {}
    /// Skips to the next queue/up next item.
    public func advance() async {}

    // MARK: Sleep timer

    public func setSleepTimer(_ preset: SleepTimerPreset) {}
    /// Sleep at the end of the given chapter.
    public func setSleepTimer(endOf chapter: Chapter) {}
    public func extendSleepTimer() {}
    /// ±1 minute or ±1 chapter; cancels when going below the minimum.
    public func adjustSleepTimer(by delta: Int) {}
    public func cancelSleepTimer() {}

    // MARK: Bookmarks

    /// Creates a bookmark at the current position. `nil` note = quick bookmark (formatted date).
    @discardableResult
    public func createBookmark(note: String? = nil) async throws -> Bookmark {
        throw PlaybackError.noPlaybackItem
    }

    // MARK: Item state hooks

    /// Marks the current item finished (seeks to end → normal finish flow), or forwards to ProgressStore.
    public func setFinished(_ id: ItemIdentifier, finished: Bool) async throws {}

    /// Whether `id` is the current item.
    public func isCurrent(_ id: ItemIdentifier) -> Bool { currentItem?.id == id }
}
