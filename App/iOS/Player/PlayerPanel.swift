import HearthData
import HearthModel
import HearthPlayback
import HearthUI
import SwiftUI
import TipKit

/// Panel shown instead of the large cover: bookmarks + chapters (or the episode description) and the queue.
struct PlayerPanel: View {
    enum Page: Hashable {
        case chapters
        case queue
    }

    @Binding var page: Page
    var onError: (any Error) -> Void = { _ in }

    private var player: AudioPlayer { .shared }

    private var firstPageTitle: String {
        if player.chapters.count > 1 {
            return String(localized: "Chapters", table: "Player")
        }
        if case .episode = player.currentItem {
            return String(localized: "Episode", table: "Player")
        }
        return String(localized: "Bookmarks", table: "Player")
    }

    var body: some View {
        VStack(spacing: 10) {
            Picker(selection: $page) {
                Text(firstPageTitle).tag(Page.chapters)
                Text("Queue", tableName: "Player").tag(Page.queue)
            } label: {
                Text("Panel", tableName: "Player")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 4)

            switch page {
            case .chapters:
                ChaptersPage(onError: onError)
            case .queue:
                QueuePage()
            }
        }
    }
}

// MARK: - Chapters & bookmarks

private struct ChaptersPage: View {
    let onError: (any Error) -> Void

    @State private var editing: Bookmark?
    @State private var note = ""

    private var player: AudioPlayer { .shared }

    var body: some View {
        let bookmarks = player.currentItem.map { HearthData.shared.bookmarks.bookmarks(for: $0.id) } ?? []
        let chapters = player.chapters
        ScrollViewReader { proxy in
            List {
                if !bookmarks.isEmpty {
                    Section {
                        ForEach(bookmarks) { bookmark in
                            Button {
                                Task { await player.seek(to: TimeInterval(bookmark.time)) }
                            } label: {
                                PlayerBookmarkRow(bookmark: bookmark)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task {
                                        do { try await HearthData.shared.bookmarks.delete(bookmark) } catch { onError(error) }
                                    }
                                } label: {
                                    Label(String(localized: "Delete", table: "Player"), systemImage: "trash")
                                }
                                Button {
                                    note = bookmark.note
                                    editing = bookmark
                                } label: {
                                    Label(String(localized: "Edit Note", table: "Player"), systemImage: "pencil")
                                }
                                .tint(.orange)
                            }
                        }
                    } header: {
                        Text("Bookmarks", tableName: "Player")
                    }
                    .listRowBackground(Color.clear)
                }

                if chapters.count > 1 {
                    Section {
                        ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                            PlayerChapterRow(chapter: chapter, index: index)
                                .id(chapter.id)
                        }
                    } header: {
                        Text("Chapters", tableName: "Player")
                    }
                    .listRowBackground(Color.clear)
                } else if case .episode(let episode) = player.currentItem {
                    Section {
                        EpisodeDescription(episode: episode)
                    }
                    .listRowBackground(Color.clear)
                } else if bookmarks.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "No Chapters", table: "Player"), systemImage: "list.bullet")
                    } description: {
                        Text("Bookmarks you add appear here.", tableName: "Player")
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onAppear {
                if let id = player.currentChapter?.id {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: player.currentChapterIndex) { _, _ in
                guard let id = player.currentChapter?.id else { return }
                withAnimation(.smooth) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .alert(String(localized: "Edit Note", table: "Player"), isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField(String(localized: "Note", table: "Player"), text: $note)
            Button(String(localized: "Save", table: "Player")) {
                guard let bookmark = editing else { return }
                let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
                Task {
                    do { try await HearthData.shared.bookmarks.update(bookmark, note: text) } catch { onError(error) }
                }
            }
            Button(String(localized: "Cancel", table: "Player"), role: .cancel) {}
        }
    }
}

private struct PlayerBookmarkRow: View {
    let bookmark: Bookmark

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bookmark.fill")
                .foregroundStyle(.tint)
            Text(bookmark.note)
                .font(.subheadline)
                .lineLimit(2)
            Spacer(minLength: 8)
            Text(HearthFormat.clock(TimeInterval(bookmark.time)))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

private struct PlayerChapterRow: View {
    let chapter: Chapter
    let index: Int

    @State private var sleepTrigger = 0

    private var player: AudioPlayer { .shared }

    var body: some View {
        let current = player.currentChapterIndex == index
        let past = (player.currentChapterIndex ?? -1) > index
        Button {
            Task { await player.seek(toChapter: chapter) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(chapter.title)
                        .font(.subheadline.weight(current ? .bold : .regular))
                        .lineLimit(2)
                    if current {
                        ProgressCapsule(progress: chapter.duration > 0 ? (player.currentTime - chapter.start) / chapter.duration : 0, height: 3, tint: .primary)
                            .frame(maxWidth: 160)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(HearthFormat.duration(chapter.duration / max(player.playbackRate, 0.01)))
                    if !past, let ends = endDate {
                        Text("Ends \(ends.formatted(date: .omitted, time: .shortened))", tableName: "Player")
                            .font(.caption2)
                    }
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            .foregroundStyle(past ? .secondary : .primary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading) {
            if !past {
                Button {
                    sleepTrigger += 1
                    player.setSleepTimer(endOf: chapter)
                } label: {
                    Label(String(localized: "Sleep at End", table: "Player"), systemImage: "moon.zzz")
                }
                .tint(.indigo)
            }
        }
        .sensoryFeedback(.success, trigger: sleepTrigger)
        .accessibilityValue(current ? String(localized: "Current chapter", table: "Player") : (past ? String(localized: "Played", table: "Player") : ""))
        .accessibilityAction(named: String(localized: "Sleep at end of this chapter", table: "Player")) {
            player.setSleepTimer(endOf: chapter)
        }
    }

    /// Wall-clock time at which this chapter ends at the current rate.
    private var endDate: Date? {
        let remaining = chapter.end - player.currentTime
        guard remaining > 0 else { return nil }
        return Date.now.addingTimeInterval(remaining / max(player.playbackRate, 0.01))
    }
}

/// Episode description with tappable timestamps (seek within the current episode).
private struct EpisodeDescription: View {
    let episode: Episode

    @State private var text: AttributedString?

    var body: some View {
        Group {
            if let text {
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
            } else {
                Text("No description.", tableName: "Player")
                    .foregroundStyle(.secondary)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if let seconds = HTMLText.seekTime(from: url) {
                Task { await AudioPlayer.shared.seek(to: seconds) }
                return .handled
            }
            return .systemAction
        })
        .task(id: episode.id) {
            guard let html = episode.descriptionHTML, !html.isEmpty else { return }
            text = await Task.detached(priority: .userInitiated) {
                HTMLText.attributedString(from: html, linkTimestamps: true)
            }.value
        }
    }
}

// MARK: - Queue

private struct QueuePage: View {
    @Environment(\.itemActionHandler) private var handler
    @State private var trigger = 0

    private var player: AudioPlayer { .shared }

    var body: some View {
        List {
            if player.queue.isEmpty, player.upNext.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "Nothing Queued", table: "Player"), systemImage: "text.line.last.and.arrowtriangle.forward")
                } description: {
                    Text("Use “Play Next” or “Add to Queue” on any audiobook or episode.", tableName: "Player")
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                TipView(PlayerTips.upNext)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if !player.queue.isEmpty {
                Section {
                    ForEach(Array(player.queue.enumerated()), id: \.element.id) { index, item in
                        Button {
                            trigger += 1
                            Task { await player.jumpToQueueItem(at: index) }
                        } label: {
                            CompactItemRow(item: item, coverSize: 44)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .leading) {
                            Button {
                                Task { await player.jumpToQueueItem(at: index) }
                            } label: {
                                Label(String(localized: "Play Now", table: "Player"), systemImage: "play.fill")
                            }
                            .tint(.accentColor)
                        }
                    }
                    .onMove { source, destination in
                        player.moveQueueItems(from: source, to: destination)
                    }
                    .onDelete { offsets in
                        player.removeFromQueue(at: offsets)
                    }
                } header: {
                    HStack {
                        Text("Queue", tableName: "Player")
                        Spacer()
                        Button(String(localized: "Clear", table: "Player")) {
                            withAnimation { player.clearQueue() }
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                }
                .listRowBackground(Color.clear)
            }

            if !player.upNext.isEmpty {
                Section {
                    TipView(PlayerTips.upNext)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    ForEach(Array(player.upNext.enumerated()), id: \.element.id) { index, item in
                        Button {
                            trigger += 1
                            Task { await player.jumpToUpNextItem(at: index) }
                        } label: {
                            CompactItemRow(item: item, coverSize: 44)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .leading) {
                            Button {
                                withAnimation { player.promoteUpNextItem(at: index) }
                            } label: {
                                Label(String(localized: "Add to Queue", table: "Player"), systemImage: "text.badge.plus")
                            }
                            .tint(.accentColor)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                withAnimation { player.removeFromUpNext(at: IndexSet(integer: index)) }
                            } label: {
                                Label(String(localized: "Remove", table: "Player"), systemImage: "minus.circle")
                            }
                        }
                    }
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Up Next", tableName: "Player")
                            if let source = player.upNextSource {
                                Text(source)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textCase(nil)
                            }
                        }
                        Spacer()
                        Button(String(localized: "Clear", table: "Player")) {
                            withAnimation { player.clearUpNext() }
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .sensoryFeedback(.impact(weight: .light), trigger: trigger)
    }
}
