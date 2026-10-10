import HearthData
import HearthModel
import HearthPlayback
import SwiftUI

/// Menu-bar commands and hardware keyboard shortcuts (iPad / Mac).
struct HearthCommands: Commands {
    @FocusedValue(\.navigator) private var navigator

    var body: some Commands {
        CommandMenu("Playback") {
            Button(AudioPlayer.shared.isPlaying ? "Pause" : "Play") {
                AudioPlayer.shared.togglePlayPause()
            }
            .keyboardShortcut(.space, modifiers: [])

            Button("Skip Back") {
                Task { await AudioPlayer.shared.skipBackward() }
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)

            Button("Skip Forward") {
                Task { await AudioPlayer.shared.skipForward() }
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)

            Divider()

            Button("Previous Chapter") {
                Task { await AudioPlayer.shared.previousChapter() }
            }
            .keyboardShortcut("[", modifiers: .command)

            Button("Next Chapter") {
                Task { await AudioPlayer.shared.nextChapter() }
            }
            .keyboardShortcut("]", modifiers: .command)

            Divider()

            Button("Add Bookmark…") {
                navigator?.isBookmarkPromptPresented = true
            }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(AudioPlayer.shared.currentItem?.id.kind != .audiobook)
        }

        CommandMenu("Go") {
            Button("Search") {
                navigator?.showSearch(query: nil)
            }
            .keyboardShortcut("f", modifiers: .command)

            Button("Listen Now") {
                navigator?.sheet = .listenNow
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Divider()

            ForEach(Array(visibleTabs.prefix(9).enumerated()), id: \.offset) { index, tab in
                Button(tab.title) {
                    navigator?.selectedTab = tab.value
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                navigator?.sheet = .settings
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }

    private struct ShortcutTab {
        var title: String
        var value: TabValue
    }

    /// Tabs reachable with ⌘1…⌘9: the current library's tabs (or pinned tabs).
    @MainActor
    private var visibleTabs: [ShortcutTab] {
        guard let navigator else { return [] }
        let connections = HearthData.shared.connections
        return navigator.compactTabs(connections: connections, pinned: HearthData.shared.itemSettings.pinnedTabs).compactMap { value in
            guard let tab = value.libraryTab else { return nil }
            return ShortcutTab(title: tab.title, value: value)
        }
    }
}
