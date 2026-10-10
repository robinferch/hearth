// PLACEHOLDER DETAIL SCREENS – the detail-screen agent replaces these bodies (keep the type names and
// initializers; they are referenced from `DestinationView` in Navigation/DestinationView.swift).
//
// Available to every detail view through the environment:
// - `\.itemActionHandler` (play / queue / download / navigate / add to…), `Navigator`, `AlertCenter`,
//   `PlayerPresentation`.
// - `.itemUserActivity(id)` (Navigation/UserActivityModifier.swift) to advertise Handoff for the item.
// - HearthUI: `ItemCover`, `PlayButton`, `DominantColorReader` / `.dominantColorBackground(for:)`,
//   `.hearthTitle()`, rows (`AudiobookRow`, `EpisodeRow`, `CompactItemRow`, …), `LoadStateView`.

import HearthData
import HearthModel
import HearthUI
import SwiftUI

struct AudiobookDetailView: View {
    let id: ItemIdentifier

    var body: some View {
        PlaceholderItemDetail(id: id)
    }
}

struct PodcastDetailView: View {
    let id: ItemIdentifier

    var body: some View {
        PlaceholderItemDetail(id: id) {
            NavigationLink(value: NavigationDestination.allEpisodes(podcast: id)) {
                Label("All Episodes", systemImage: "list.bullet")
            }
        }
    }
}

struct EpisodeDetailView: View {
    let id: ItemIdentifier

    var body: some View {
        PlaceholderItemDetail(id: id)
    }
}

struct SeriesDetailView: View {
    let id: ItemIdentifier

    var body: some View {
        PlaceholderItemDetail(id: id)
    }
}

/// Authors and narrators (`id.kind` is `.author` or `.narrator`).
struct PersonDetailView: View {
    let id: ItemIdentifier

    var body: some View {
        PlaceholderItemDetail(id: id)
    }
}

/// Collections and playlists (`id.kind` is `.collection` or `.playlist`).
struct CollectionDetailView: View {
    let id: ItemIdentifier

    var body: some View {
        PlaceholderItemDetail(id: id)
    }
}

struct AllEpisodesView: View {
    let podcastID: ItemIdentifier

    @State private var state: LoadState<[Episode]> = .loading

    var body: some View {
        LoadStateView(state, retry: load) { episodes in
            if episodes.isEmpty {
                EmptyStateView(title: String(localized: "No Episodes"), systemImage: "antenna.radiowaves.left.and.right")
            } else {
                List(episodes) { episode in
                    NavigationLink(value: NavigationDestination.item(episode.id)) {
                        EpisodeRow(episode: episode, showsCover: false, context: .podcastPage)
                    }
                    .itemActions(for: .episode(episode), context: .podcastPage)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("All Episodes")
        .task { await load() }
    }

    private func load() async {
        do {
            state = .loaded(try await HearthData.shared.items.podcast(podcastID).episodes)
        } catch {
            state = .failed(error)
        }
    }
}

// MARK: - Shared placeholder

/// Minimal item page: cover, title, play button and description.
private struct PlaceholderItemDetail<Extra: View>: View {
    let id: ItemIdentifier
    let extra: Extra

    @State private var state: LoadState<AnyItem> = .loading

    init(id: ItemIdentifier, @ViewBuilder extra: () -> Extra = { EmptyView() }) {
        self.id = id
        self.extra = extra()
    }

    var body: some View {
        LoadStateView(state, retry: load) { item in
            ScrollView {
                VStack(spacing: 16) {
                    ItemCover(id: item.id, size: .regular, cornerRadius: 14)
                        .frame(maxWidth: 260)
                    Text(item.name)
                        .hearthTitle(.title2)
                        .multilineTextAlignment(.center)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .foregroundStyle(.secondary)
                    }
                    if let playable = item.playable {
                        PlayButton(item: playable)
                            .frame(maxWidth: 420)
                    }
                    extra
                    if let description = HearthFormat.plainText(fromHTML: item.base.descriptionHTML) {
                        Text(description)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
        }
        .itemUserActivity(id)
        .task { await load() }
    }

    private func load() async {
        do {
            state = .loaded(try await HearthData.shared.items.item(id))
        } catch {
            state = .failed(error)
        }
    }
}
