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
        /// The item playing now (the timer outlives item changes; `nil` = the item from the attributes).
        public var itemID: String?
        public var title: String?
        public var subtitle: String?
        /// Cover file name inside `SharedSnapshotStore.imagesDirectory`.
        public var coverFile: String?

        public init(mode: Mode, deadline: Date? = nil, remaining: TimeInterval? = nil, chaptersRemaining: Int? = nil, chapterEnd: Date? = nil, isPlaying: Bool, isExpired: Bool = false, chapterTitle: String? = nil, itemID: String? = nil, title: String? = nil, subtitle: String? = nil, coverFile: String? = nil) {
            self.mode = mode
            self.deadline = deadline
            self.remaining = remaining
            self.chaptersRemaining = chaptersRemaining
            self.chapterEnd = chapterEnd
            self.isPlaying = isPlaying
            self.isExpired = isExpired
            self.chapterTitle = chapterTitle
            self.itemID = itemID
            self.title = title
            self.subtitle = subtitle
            self.coverFile = coverFile
        }
    }

    /// `ItemIdentifier.description` of the item that was playing when the activity started
    /// (the item fields of `ContentState` win when set).
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

    /// The current item's values: content state first, the attributes of the start as fallback.
    public func itemID(_ state: ContentState) -> String { state.itemID ?? itemID }
    public func title(_ state: ContentState) -> String { state.title ?? title }
    public func coverFile(_ state: ContentState) -> String? { state.itemID == nil ? coverFile : state.coverFile }
}
#endif
