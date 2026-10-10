// PLACEHOLDER PLAYER UI – the player agent replaces the bodies of `MiniPlayerView` and `NowPlayingView`.
//
// Wiring that already exists (keep the type names / initializers):
// - `MainTabView` shows `MiniPlayerView()` in `.tabViewBottomAccessory` whenever something is playing or a
//   last-played item is known; `OfflineView` shows it as a bottom safe-area inset.
// - Tapping the mini player calls `PlayerPresentation.expand()`; `MainTabView` / `OfflineView` present
//   `NowPlayingView()` as a `.fullScreenCover` with `.navigationTransition(.zoom(...))` from the mini player
//   (`.matchedTransitionSource(id: PlayerPresentation.transitionSourceID, in: playerNamespace)`).
// - Environment available inside both views: `PlayerPresentation`, `Navigator`, `AlertCenter`,
//   `\.itemActionHandler`, `\.playerNamespace`.

import HearthData
import HearthModel
import HearthPlayback
import HearthUI
import SwiftUI

/// Bottom accessory mini player. Minimal placeholder: cover, title and play/pause.
struct MiniPlayerView: View {
    @Environment(PlayerPresentation.self) private var presentation
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(\.playerNamespace) private var namespace

    private var player: AudioPlayer { .shared }

    var body: some View {
        HStack(spacing: 10) {
            ItemImage(id: player.currentItem?.id ?? player.lastPlayedItemID, size: .tiny, cornerRadius: 6)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if player.currentItem != nil {
                if placement != .inline {
                    Button {
                        Task { await player.skipBackward() }
                    } label: {
                        Image(systemName: "gobackward.\(AppSettings.shared.skipBackwardInterval)")
                    }
                    .accessibilityLabel("Skip back")
                }
                Button {
                    player.togglePlayPause()
                } label: {
                    if player.isBuffering {
                        ProgressView()
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            } else {
                Button {
                    Task { try? await player.resumeLastPlayed() }
                } label: {
                    Label("Resume", systemImage: "play.fill")
                        .labelStyle(.titleAndIcon)
                }
            }
        }
        .font(.title3)
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .contentShape(.rect)
        .onTapGesture {
            presentation.expand()
        }
        .modifier(MatchedSourceModifier(namespace: namespace))
        .accessibilityAction(named: "Open player") {
            presentation.expand()
        }
    }

    private var title: String {
        if let item = player.currentItem {
            return item.name
        }
        return String(localized: "Not Playing")
    }

    private var subtitle: String? {
        if let chapter = player.currentChapter {
            return chapter.title
        }
        return player.currentItem?.base.subtitleLine
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

/// Full-screen player. Placeholder: cover, title and transport controls.
struct NowPlayingView: View {
    @Environment(PlayerPresentation.self) private var presentation

    private var player: AudioPlayer { .shared }

    var body: some View {
        VStack(spacing: 28) {
            Capsule()
                .fill(.secondary.opacity(0.5))
                .frame(width: 40, height: 5)
                .padding(.top, 8)

            Spacer(minLength: 0)

            ItemImage(id: player.currentItem?.id ?? player.lastPlayedItemID, size: .large, cornerRadius: 16)
                .frame(maxWidth: 360)
                .shadow(radius: 20, y: 10)
                .padding(.horizontal, 32)

            VStack(spacing: 4) {
                Text(player.currentItem?.name ?? String(localized: "Not Playing"))
                    .hearthTitle(.title2)
                    .multilineTextAlignment(.center)
                if let chapter = player.currentChapter {
                    Text(chapter.title)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)

            HStack(spacing: 44) {
                Button {
                    Task { await player.skipBackward() }
                } label: {
                    Image(systemName: "gobackward.\(AppSettings.shared.skipBackwardInterval)")
                }
                .accessibilityLabel("Skip back")
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 48))
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button {
                    Task { await player.skipForward() }
                } label: {
                    Image(systemName: "goforward.\(AppSettings.shared.skipForwardInterval)")
                }
                .accessibilityLabel("Skip forward")
            }
            .font(.title)
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .overlay(alignment: .topTrailing) {
            Button {
                presentation.collapse()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.headline)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .padding()
            .accessibilityLabel("Close player")
        }
    }
}
