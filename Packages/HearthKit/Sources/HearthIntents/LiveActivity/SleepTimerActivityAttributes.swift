#if os(iOS)
import ActivityKit
import Foundation
import HearthData
import HearthModel

/// Live Activity shown while a sleep timer is active (started by the app, rendered by the widget extension).
public struct SleepTimerActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public enum Mode: String, Codable, Hashable, Sendable {
            case duration
            case chapters
        }

        public var mode: Mode
        /// When a running duration timer fires.
        public var deadline: Date?
        /// Remaining time of a paused duration timer.
        public var remaining: TimeInterval?
        /// Chapters left for chapter based timers (1 = end of the current chapter).
        public var chaptersRemaining: Int?
        /// Estimated wall-clock end of the current chapter while playing (chapter timers).
        public var chapterEnd: Date?
        public var isPlaying: Bool
        /// The timer fired and paused playback; the activity offers to resume / extend.
        public var isExpired: Bool
        public var chapterTitle: String?

        public init(mode: Mode, deadline: Date? = nil, remaining: TimeInterval? = nil, chaptersRemaining: Int? = nil, chapterEnd: Date? = nil, isPlaying: Bool, isExpired: Bool = false, chapterTitle: String? = nil) {
            self.mode = mode
            self.deadline = deadline
            self.remaining = remaining
            self.chaptersRemaining = chaptersRemaining
            self.chapterEnd = chapterEnd
            self.isPlaying = isPlaying
            self.isExpired = isExpired
            self.chapterTitle = chapterTitle
        }
    }

    /// `ItemIdentifier.description` of the item that was playing when the activity started.
    public var itemID: String
    public var title: String
    public var subtitle: String?
    /// Cover file name inside `SharedSnapshotStore.imagesDirectory`.
    public var coverFile: String?
    public var tint: TintColor

    public init(itemID: String, title: String, subtitle: String?, coverFile: String?, tint: TintColor) {
        self.itemID = itemID
        self.title = title
        self.subtitle = subtitle
        self.coverFile = coverFile
        self.tint = tint
    }
}
#endif
