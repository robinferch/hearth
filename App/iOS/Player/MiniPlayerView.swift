import HearthData
import HearthModel
import HearthPlayback
import HearthUI
import SwiftUI

/// Bottom accessory mini player (glass pill provided by the tab view).
///
/// Cover, two-line title (book + chapter / date + episode), skip back (hidden when the accessory is inline),
/// play/pause with buffering state; a "Resume" pill when idle. On iPad (regular width, expanded) it also shows
/// speed, skip forward and the sleep timer. Tap opens the full player, long-press shows a context menu.
struct MiniPlayerView: View {
    @Environment(PlayerPresentation.self) private var presentation
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.playerNamespace) private var namespace
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.itemActionHandler) private var handler

    @State private var lastPlayed: AnyPlayableItem?

    private var player: AudioPlayer { .shared }
    private var item: AnyPlayableItem? { player.currentItem ?? lastPlayed }
    private var isIdle: Bool { player.currentItem == nil }
    private var isInline: Bool { placement == .inline }
    private var showsExtendedControls: Bool { sizeClass == .regular && !isInline && !isIdle }

    var body: some View {
        HStack(spacing: 10) {
            ItemImage(id: player.currentItem?.id ?? player.lastPlayedItemID, size: .tiny, cornerRadius: 7)
                .frame(width: isInline ? 28 : 36, height: isInline ? 28 : 36)
                .accessibilityHidden(true)
            titles
                .frame(maxWidth: .infinity, alignment: .leading)
            controls
        }
        .padding(.leading, isInline ? 8 : 10)
        .padding(.trailing, isInline ? 6 : 10)
        .contentShape(.rect)
        .onTapGesture {
            presentation.expand()
        }
        .contextMenu {
            contextMenu
        }
        .modifier(MatchedSourceModifier(namespace: namespace))
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: String(localized: "Open Player", table: "Player")) {
            presentation.expand()
        }
        .task(id: player.lastPlayedItemID) {
            PlayerTips.configureIfNeeded()
            guard player.currentItem == nil, let id = player.lastPlayedItemID else {
                lastPlayed = nil
                return
            }
            lastPlayed = try? await HearthData.shared.items.playable(id)
        }
        .onChange(of: player.startedItemAt) { _, started in
            // Items started elsewhere (Siri, widgets, CarPlay hand-off, queue) also open the player.
            guard let started, scenePhase == .active, Date.now.timeIntervalSince(started) < 3 else { return }
            presentation.itemStarted()
        }
    }

    // MARK: Titles

    private var titles: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch item {
            case .episode(let episode):
                Text(HearthFormat.joined([episode.publishedAt.map { HearthFormat.releaseDate($0) }, episode.podcastName]))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(episode.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            case .audiobook(let book):
                Text(book.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let secondLine = audiobookSecondLine(book), !isInline {
                    Text(secondLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            case nil:
                Text("Not Playing", tableName: "Player")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(String(localized: "Opens the player", table: "Player"))
    }

    private func audiobookSecondLine(_ book: Audiobook) -> String? {
        if isIdle {
            if let progress = HearthData.shared.progress.progress(for: book.id), progress.isInProgress {
                return HearthFormat.remaining(progress.remaining ?? 0, rate: ItemStatus.effectiveRate(for: book.id))
            }
            return book.authorLine
        }
        return player.currentChapter?.title ?? book.authorLine
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        if isIdle {
            Button {
                Task { try? await player.resumeLastPlayed() }
            } label: {
                Label(String(localized: "Resume", table: "Player"), systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.tint.opacity(0.18), in: .capsule)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .disabled(player.lastPlayedItemID == nil)
        } else {
            HStack(spacing: showsExtendedControls ? 14 : 4) {
                if showsExtendedControls {
                    SpeedButton(font: .subheadline.weight(.semibold))
                }
                if !isInline {
                    MiniSkipButton(forward: false)
                }
                Button {
                    player.togglePlayPause()
                } label: {
                    Group {
                        if player.isBuffering {
                            ProgressView()
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .font(.title3)
                    .frame(width: 40, height: 40)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.impact(weight: .light), trigger: player.isPlaying)
                .accessibilityLabel(player.isPlaying ? String(localized: "Pause", table: "Player") : String(localized: "Play", table: "Player"))
                if showsExtendedControls {
                    MiniSkipButton(forward: true)
                    SleepTimerButton(font: .body)
                }
            }
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private var contextMenu: some View {
        if let item {
            let status = ItemStatus.of(item.id)
            Section {
                if !isIdle {
                    Button {
                        Task {
                            presentation.stoppedAt = .now
                            await player.stop()
                        }
                    } label: {
                        Label(String(localized: "Stop Playback", table: "Player"), systemImage: "stop.fill")
                    }
                }
                Button {
                    Task { await handler.setFinished(item.id, !status.isFinished) }
                } label: {
                    if status.isFinished {
                        Label(String(localized: "Mark as Unfinished", table: "Player"), systemImage: "arrow.uturn.backward.circle")
                    } else {
                        Label(String(localized: "Mark as Finished", table: "Player"), systemImage: "checkmark.circle")
                    }
                }
                Button {
                    handler.addTo(item.id)
                } label: {
                    Label(String(localized: "Add to…", table: "Player"), systemImage: "text.badge.plus")
                }
            }
            Section {
                PlayerItemLinks(item: item)
            }
        }
    }
}

/// Small skip button for the mini player (tap combining, long-press chapter jump).
private struct MiniSkipButton: View {
    let forward: Bool

    var body: some View {
        SkipButton(forward: forward, size: 17)
            .frame(width: 36, height: 40)
    }
}

private struct MatchedSourceModifier: ViewModifier {
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedTransitionSource(id: PlayerPresentation.transitionSourceID, in: namespace)
        } else {
            content
        }
    }
}
