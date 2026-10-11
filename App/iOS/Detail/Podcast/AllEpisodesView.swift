import HearthData
import HearthModel
import HearthPlayback
import HearthUI
import SwiftUI

/// All episodes of a podcast: season capsules, search, filter/sort and a select mode with bulk actions.
struct AllEpisodesView: View {
    let podcastID: ItemIdentifier

    @State private var loader: DetailLoader<PodcastContent>

    init(podcastID: ItemIdentifier) {
        self.podcastID = podcastID
        _loader = State(initialValue: DetailLoader {
            let result = try await HearthData.shared.items.podcast(podcastID)
            return PodcastContent(podcast: result.podcast, episodes: result.episodes)
        })
    }

    var body: some View {
        LoadStateView(loader.state, retry: { await loader.reload() }) { content in
            AllEpisodesContent(content: content) {
                HearthData.shared.items.invalidate(podcastID)
                await loader.reload()
            }
        }
        .navigationTitle(String(localized: "All Episodes", table: "Detail"))
        .task {
            if loader.value == nil {
                await loader.reload()
            }
        }
    }
}

private struct AllEpisodesContent: View {
    let content: PodcastContent
    let refresh: @MainActor () async -> Void

    @Environment(\.itemActionHandler) private var handler
    @Environment(AlertCenter.self) private var alerts
    @Environment(PlayerPresentation.self) private var presentation

    @State private var searchText = ""
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<ItemIdentifier>()
    @State private var bulkTrigger = 0
    /// Plain-text descriptions for search, built once off the main thread (HTML stripping is slow).
    @State private var plainDescriptions: [ItemIdentifier: String] = [:]

    /// Read and written through the store (not copied into state): the podcast page edits the same settings.
    private var settings: EpisodeListSettings { HearthData.shared.itemSettings.episodeListSettings(for: content.podcast) }
    private var settingsBinding: Binding<EpisodeListSettings> {
        let podcast = content.podcast
        return Binding(
            get: { HearthData.shared.itemSettings.episodeListSettings(for: podcast) },
            set: { HearthData.shared.itemSettings.setEpisodeListSettings($0, for: podcast.id) }
        )
    }

    private var seasons: [String] { HearthData.shared.itemSettings.seasons(in: content.episodes) }

    private var episodes: [Episode] {
        let applied = HearthData.shared.itemSettings.apply(settings, to: content.episodes)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return applied }
        return applied.filter { episode in
            episode.name.localizedStandardContains(query)
                || (plainDescriptions[episode.id]?.localizedStandardContains(query) ?? false)
        }
    }

    private var isSelecting: Bool { editMode.isEditing }

    var body: some View {
        let episodes = episodes
        List(selection: $selection) {
            if seasons.count >= 2 {
                SeasonCapsules(seasons: seasons, selection: settingsBinding.season)
                    .detailPlainRow(insets: EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                    .selectionDisabled()
            }
            if episodes.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No Episodes", table: "Detail"), systemImage: "antenna.radiowaves.left.and.right")
                } description: {
                    Text("No episodes match the current filter.", tableName: "Detail")
                }
                .detailPlainRow()
                .selectionDisabled()
            }
            ForEach(episodes) { episode in
                NavigationLink(value: NavigationDestination.item(episode.id)) {
                    EpisodeRow(episode: episode, showsCover: false, descriptionLines: 2, context: .podcastPage)
                }
                .itemActions(for: .episode(episode), swipeActions: !isSelecting, context: .podcastPage)
                .tag(episode.id)
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        .environment(\.itemActionHandler, handler.withPlaybackOrigin(.podcast(content.podcast.id), alerts: alerts, presentation: presentation))
        .searchable(text: $searchText, prompt: Text("Search Episodes", tableName: "Detail"))
        .refreshable { await refresh() }
        .task(id: content.episodes.map(\.id)) {
            let episodes = content.episodes
            let descriptions = await Task.detached(priority: .utility) {
                var result: [ItemIdentifier: String] = [:]
                for episode in episodes {
                    result[episode.id] = HearthFormat.plainText(fromHTML: episode.descriptionHTML)
                }
                return result
            }.value
            plainDescriptions = descriptions
        }
        .onChange(of: editMode) { _, mode in
            if !mode.isEditing {
                selection.removeAll()
            }
        }
        .sensoryFeedback(.success, trigger: bulkTrigger)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !isSelecting {
                    EpisodeListOptionsButton(settings: settingsBinding)
                }
                Button {
                    withAnimation {
                        editMode = isSelecting ? .inactive : .active
                    }
                } label: {
                    Text(isSelecting ? String(localized: "Done", table: "Detail") : String(localized: "Select", table: "Detail"))
                }
            }
            if isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if selection.count == episodes.count {
                            selection.removeAll()
                        } else {
                            selection = Set(episodes.map(\.id))
                        }
                    } label: {
                        Text(selection.count == episodes.count ? String(localized: "Deselect All", table: "Detail") : String(localized: "Select All", table: "Detail"))
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    bulkActions
                }
            }
        }
    }

    @ViewBuilder
    private var bulkActions: some View {
        let ids = selectedIDs
        let disabled = ids.isEmpty
        Button {
            Task {
                await AudioPlayer.shared.addToQueue(ids)
                finishBulk()
            }
        } label: {
            Label(String(localized: "Add to Queue", table: "Detail"), systemImage: "text.line.last.and.arrowtriangle.forward")
        }
        .disabled(disabled)
        Spacer()
        Button {
            Task {
                await HearthData.shared.downloads.download(ids)
                finishBulk()
            }
        } label: {
            Label(String(localized: "Download", table: "Detail"), systemImage: "arrow.down.circle")
        }
        .disabled(disabled)
        Spacer()
        Menu {
            Button {
                Task {
                    for id in ids { await handler.setFinished(id, true) }
                    finishBulk()
                }
            } label: {
                Label(String(localized: "Mark as Finished", table: "Detail"), systemImage: "checkmark.circle")
            }
            Button {
                Task {
                    for id in ids { await handler.setFinished(id, false) }
                    finishBulk()
                }
            } label: {
                Label(String(localized: "Mark as Unfinished", table: "Detail"), systemImage: "arrow.uturn.backward.circle")
            }
            Button(role: .destructive) {
                Task {
                    let downloads = HearthData.shared.downloads
                    for id in ids where downloads.status(of: id) != .none && !AudioPlayer.shared.isCurrent(id) {
                        await downloads.remove(id)
                    }
                    finishBulk()
                }
            } label: {
                Label(String(localized: "Remove Downloads", table: "Detail"), systemImage: "trash")
            }
        } label: {
            Label(String(localized: "More", table: "Detail"), systemImage: "ellipsis.circle")
        }
        .disabled(disabled)
    }

    /// Selected ids in list order.
    private var selectedIDs: [ItemIdentifier] {
        episodes.map(\.id).filter(selection.contains)
    }

    private func finishBulk() {
        bulkTrigger += 1
        withAnimation {
            editMode = .inactive
        }
    }
}

/// Horizontal capsule picker: "All" + one capsule per season.
private struct SeasonCapsules: View {
    let seasons: [String]
    @Binding var selection: String?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                capsule(title: String(localized: "All", table: "Detail"), value: nil)
                ForEach(seasons, id: \.self) { season in
                    capsule(title: SeasonFormat.title(season), value: season)
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func capsule(title: String, value: String?) -> some View {
        let isSelected = selection == value
        return Button {
            withAnimation(.snappy) { selection = value }
        } label: {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background {
                    Capsule().fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
