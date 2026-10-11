import AppIntents
import HearthIntents

/// Siri / Spotlight App Shortcuts. Phrases are localized in `AppShortcuts.xcstrings`.
struct HearthShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .orange

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayAudiobookIntent(),
            phrases: [
                "Play \(\.$audiobook) in \(.applicationName)",
                "Listen to \(\.$audiobook) in \(.applicationName)",
                "Play an audiobook in \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("Play Audiobook", table: "System"),
            systemImageName: "book"
        )
        AppShortcut(
            intent: PlayPodcastIntent(),
            phrases: [
                "Play \(\.$podcast) in \(.applicationName)",
                "Play a podcast in \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("Play Podcast", table: "System"),
            systemImageName: "antenna.radiowaves.left.and.right"
        )
        AppShortcut(
            intent: ResumeIntent(),
            phrases: [
                "Resume \(.applicationName)",
                "Continue listening in \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("Resume", table: "System"),
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PauseIntent(),
            phrases: [
                "Pause \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("Pause", table: "System"),
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: SetSleepTimerIntent(),
            phrases: [
                "Set a sleep timer in \(.applicationName)",
                "Start a sleep timer in \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("Sleep Timer", table: "System"),
            systemImageName: "moon.zzz"
        )
        AppShortcut(
            intent: ExtendSleepTimerIntent(),
            phrases: [
                "Extend the sleep timer in \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("Extend Sleep Timer", table: "System"),
            systemImageName: "moon.zzz.fill"
        )
        AppShortcut(
            intent: CreateBookmarkIntent(),
            phrases: [
                "Create a bookmark in \(.applicationName)",
                "Bookmark this in \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("Bookmark", table: "System"),
            systemImageName: "bookmark"
        )
        AppShortcut(
            intent: SkipBackwardIntent(),
            phrases: [
                "Skip back in \(.applicationName)",
                "Rewind \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("Skip Backward", table: "System"),
            systemImageName: "gobackward"
        )
        AppShortcut(
            intent: NowPlayingIntent(),
            phrases: [
                "What's playing in \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("Now Playing", table: "System"),
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: OpenSearchIntent(),
            phrases: [
                "Search in \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("Search", table: "System"),
            systemImageName: "magnifyingglass"
        )
    }
}
