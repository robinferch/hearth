import AppIntents
import Foundation
import HearthData
import HearthModel
import HearthPlayback

/// Player operations shared by intents, widgets, controls and the Live Activity.
@MainActor
enum PlaybackActions {
    static var player: AudioPlayer {
        let player = AudioPlayer.shared
        if !IntentSupport.isExtension {
            // Idempotent; the app may have been launched in the background just for this intent.
            player.setup()
        }
        return player
    }

    /// Plays an item; groupings (series, podcasts, collections, authors, narrators) start their next eligible item.
    /// Resumes instead of toggling when the item is already loaded.
    static func play(_ id: ItemIdentifier) async throws {
        try IntentSupport.prepare()
        let player = player
        do {
            if id.isPlayable {
                if player.isCurrent(id) {
                    player.resume()
                } else {
                    try await player.play(id)
                }
            } else {
                let item = try await HearthData.shared.items.firstPlayable(in: id)
                if player.isCurrent(item.id) {
                    player.resume()
                } else {
                    try await player.play(grouping: id)
                }
            }
        } catch {
            throw IntentSupport.wrap(error)
        }
    }

    /// Resumes the current item, else the last played one, else the first Listen Now item.
    static func resume() async throws {
        try IntentSupport.prepare()
        let player = player
        if player.isActive {
            player.resume()
            return
        }
        do {
            if player.lastPlayedItemID != nil {
                try await player.resumeLastPlayed()
            } else if let first = await EntitySource.listenNowItems().first {
                try await player.play(first.id, origin: .listenNow)
            } else {
                throw HearthIntentError.nothingPlaying
            }
        } catch {
            throw IntentSupport.wrap(error)
        }
    }

    static func requireActive() throws -> AudioPlayer {
        let player = player
        guard player.isActive else { throw HearthIntentError.nothingPlaying }
        return player
    }
}

// MARK: - Play

/// Plays any item. Series, podcasts and collections start with their next eligible item.
public struct PlayItemIntent: AudioPlaybackIntent {
    public static let title = LocalizedStringResource("Play Item", table: "System")
    public static let description = IntentDescription(LocalizedStringResource("Plays an audiobook or episode. Series, podcasts and collections continue with their next item.", table: "System"))

    @Parameter(title: LocalizedStringResource("Item", table: "System"))
    public var item: ItemEntity

    public static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$item)", table: "System")
    }

    public init() {}

    public init(item: ItemEntity) {
        self.item = item
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        try await PlaybackActions.play(try IntentSupport.identifier(item.id))
        return .result()
    }
}

/// Plays an audiobook (books schema entity).
public struct PlayAudiobookIntent: AudioPlaybackIntent {
    public static let title = LocalizedStringResource("Play Audiobook", table: "System")
    public static let description = IntentDescription(LocalizedStringResource("Plays an audiobook from your library.", table: "System"))

    @Parameter(title: LocalizedStringResource("Audiobook", table: "System"))
    public var audiobook: AudiobookEntity

    public static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$audiobook)", table: "System")
    }

    public init() {}

    public init(audiobook: AudiobookEntity) {
        self.audiobook = audiobook
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        try await PlaybackActions.play(try IntentSupport.identifier(audiobook.id))
        return .result()
    }
}

/// Plays the next episode of a podcast (respecting the podcast's episode order and filter).
public struct PlayPodcastIntent: AudioPlaybackIntent {
    public static let title = LocalizedStringResource("Play Podcast", table: "System")
    public static let description = IntentDescription(LocalizedStringResource("Plays the next episode of a podcast.", table: "System"))

    @Parameter(title: LocalizedStringResource("Podcast", table: "System"))
    public var podcast: PodcastEntity

    public static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$podcast)", table: "System")
    }

    public init() {}

    public init(podcast: PodcastEntity) {
        self.podcast = podcast
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        try await PlaybackActions.play(try IntentSupport.identifier(podcast.id))
        return .result()
    }
}

/// Plays a podcast episode.
public struct PlayEpisodeIntent: AudioPlaybackIntent {
    public static let title = LocalizedStringResource("Play Episode", table: "System")
    public static let description = IntentDescription(LocalizedStringResource("Plays a podcast episode.", table: "System"))

    @Parameter(title: LocalizedStringResource("Episode", table: "System"))
    public var episode: EpisodeEntity

    public static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$episode)", table: "System")
    }

    public init() {}

    public init(episode: EpisodeEntity) {
        self.episode = episode
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        try await PlaybackActions.play(try IntentSupport.identifier(episode.id))
        return .result()
    }
}

// MARK: - Transport

public struct ResumeIntent: AudioPlaybackIntent {
    public static let title = LocalizedStringResource("Resume Playback", table: "System")
    public static let description = IntentDescription(LocalizedStringResource("Continues the last played audiobook or episode.", table: "System"))

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        try await PlaybackActions.resume()
        return .result()
    }
}

public struct PauseIntent: AudioPlaybackIntent {
    public static let title = LocalizedStringResource("Pause Playback", table: "System")
    public static let description = IntentDescription(LocalizedStringResource("Pauses playback.", table: "System"))

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        PlaybackActions.player.pause()
        return .result()
    }
}

public struct TogglePlaybackIntent: AudioPlaybackIntent {
    public static let title = LocalizedStringResource("Play or Pause", table: "System")
    public static let description = IntentDescription(LocalizedStringResource("Pauses playback, or resumes the last played item.", table: "System"))

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        let player = PlaybackActions.player
        if player.isPlaying {
            player.pause()
        } else {
            try await PlaybackActions.resume()
        }
        return .result()
    }
}

/// Backs the Play/Pause control (Control Center / Lock Screen).
public struct SetPlayingIntent: SetValueIntent, AudioPlaybackIntent {
    public static let title = LocalizedStringResource("Set Playing", table: "System")
    public static let isDiscoverable = false

    @Parameter(title: LocalizedStringResource("Playing", table: "System"))
    public var value: Bool

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        if value {
            try await PlaybackActions.resume()
        } else {
            PlaybackActions.player.pause()
        }
        return .result()
    }
}

public struct SkipBackwardIntent: AudioPlaybackIntent {
    public static let title = LocalizedStringResource("Skip Backward", table: "System")
    public static let description = IntentDescription(LocalizedStringResource("Skips backward by the given number of seconds, or by your skip interval.", table: "System"))

    @Parameter(title: LocalizedStringResource("Interval", table: "System"), inclusiveRange: (1, 3600))
    public var seconds: Int?

    public static var parameterSummary: some ParameterSummary {
        Summary("Skip backward \(\.$seconds) seconds", table: "System")
    }

    public init() {}

    public init(seconds: Int?) {
        self.seconds = seconds
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        let player = try PlaybackActions.requireActive()
        await player.skipBackward(seconds.map(TimeInterval.init))
        return .result()
    }
}

public struct SkipForwardIntent: AudioPlaybackIntent {
    public static let title = LocalizedStringResource("Skip Forward", table: "System")
    public static let description = IntentDescription(LocalizedStringResource("Skips forward by the given number of seconds, or by your skip interval.", table: "System"))

    @Parameter(title: LocalizedStringResource("Interval", table: "System"), inclusiveRange: (1, 3600))
    public var seconds: Int?

    public static var parameterSummary: some ParameterSummary {
        Summary("Skip forward \(\.$seconds) seconds", table: "System")
    }

    public init() {}

    public init(seconds: Int?) {
        self.seconds = seconds
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        let player = try PlaybackActions.requireActive()
        await player.skipForward(seconds.map(TimeInterval.init))
        return .result()
    }
}

public struct NextChapterIntent: AudioPlaybackIntent {
    public static let title = LocalizedStringResource("Next Chapter", table: "System")
    public static let description = IntentDescription(LocalizedStringResource("Jumps to the next chapter.", table: "System"))

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        let player = try PlaybackActions.requireActive()
        guard !player.chapters.isEmpty else { throw HearthIntentError.noChapters }
        await player.nextChapter()
        return .result()
    }
}

public struct PreviousChapterIntent: AudioPlaybackIntent {
    public static let title = LocalizedStringResource("Previous Chapter", table: "System")
    public static let description = IntentDescription(LocalizedStringResource("Jumps to the start of the chapter, or to the previous chapter.", table: "System"))

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        let player = try PlaybackActions.requireActive()
        guard !player.chapters.isEmpty else { throw HearthIntentError.noChapters }
        await player.previousChapter()
        return .result()
    }
}

public struct SetPlaybackSpeedIntent: AudioPlaybackIntent {
    public static let title = LocalizedStringResource("Set Playback Speed", table: "System")
    public static let description = IntentDescription(LocalizedStringResource("Sets the playback speed in percent (100 % is normal speed).", table: "System"))

    @Parameter(title: LocalizedStringResource("Speed (%)", table: "System"), default: 100, inclusiveRange: (25, 400))
    public var percent: Int

    public static var parameterSummary: some ParameterSummary {
        Summary("Set playback speed to \(\.$percent) %", table: "System")
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let rate = Double(min(400, max(25, percent))) / 100
        PlaybackActions.player.setPlaybackRate(rate)
        return .result(dialog: IntentSupport.dialog(IntentSupport.text("Playback speed set to \(rate.formatted(.number.precision(.fractionLength(0...2))))×.")))
    }
}

// MARK: - Bookmarks

public struct CreateBookmarkIntent: AudioPlaybackIntent {
    public static let title = LocalizedStringResource("Create Bookmark", table: "System")
    public static let description = IntentDescription(LocalizedStringResource("Bookmarks the current position of the playing audiobook.", table: "System"))

    @Parameter(title: LocalizedStringResource("Note", table: "System"))
    public var note: String?

    public static var parameterSummary: some ParameterSummary {
        Summary("Create a bookmark with \(\.$note)", table: "System")
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let player = try PlaybackActions.requireActive()
        guard player.canCreateBookmark else { throw HearthIntentError.bookmarksUnsupported }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let bookmark = try await player.createBookmark(note: trimmed?.isEmpty == false ? trimmed : nil)
            return .result(dialog: IntentSupport.dialog(IntentSupport.text("Bookmark created at \(TimeInterval(bookmark.time).clockFormatted).")))
        } catch {
            throw IntentSupport.wrap(error)
        }
    }
}

// MARK: - Now playing

public struct NowPlayingIntent: AppIntent {
    public static let title = LocalizedStringResource("Get Now Playing", table: "System")
    public static let description = IntentDescription(LocalizedStringResource("Returns the audiobook or episode that is currently playing or was played last.", table: "System"))

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<ItemEntity?> & ProvidesDialog {
        let player = AudioPlayer.shared
        if let item = player.currentItem {
            let data = await EntitySupport.imageData(for: item.id)
            let entity = ItemEntity(item, imageData: data)
            return .result(value: entity, dialog: IntentSupport.dialog(nowPlayingText(entity.title, isPlaying: player.isPlaying)))
        }
        let snapshot = SharedSnapshotStore.read()
        if let entry = snapshot.nowPlaying {
            let entity = ItemEntity(entry)
            return .result(value: entity, dialog: IntentSupport.dialog(nowPlayingText(entity.title, isPlaying: snapshot.isPlaying)))
        }
        return .result(value: nil, dialog: IntentSupport.dialog(IntentSupport.text("Nothing is playing.")))
    }

    private func nowPlayingText(_ title: String, isPlaying: Bool) -> String {
        isPlaying ? IntentSupport.text("Playing “\(title)”.") : IntentSupport.text("Paused: “\(title)”.")
    }
}
