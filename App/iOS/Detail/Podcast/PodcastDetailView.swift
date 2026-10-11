import HearthAPI
import HearthData
import HearthModel
import HearthPlayback
import HearthUI
import SwiftUI

/// Podcast page: full-bleed dominant color header, play latest/next, description, stats, season menu, the first
/// 15 episodes (filtered & sorted per podcast) and a link to all episodes.
struct PodcastDetailView: View {
    let id: ItemIdentifier

    @State private var loader: DetailLoader<PodcastContent>

    init(id: ItemIdentifier) {
        self.id = id
        _loader = State(initialValue: DetailLoader {
            let result = try await HearthData.shared.items.podcast(id)
            return PodcastContent(podcast: result.podcast, episodes: result.episodes)
        })
    }

    var body: some View {
        LoadStateView(loader.state, retry: { await loader.reload() }) { content in
            PodcastDetailContent(content: content) {
                HearthData.shared.items.invalidate(id)
                await loader.reload()
            }
        }
        .itemUserActivity(id, title: loader.value?.podcast.name)
        .task {
            if loader.value == nil {
                await loader.reload()
            }
        }
    }
}

struct PodcastContent {
    var podcast: Podcast
    var episodes: [Episode]
}

private struct PodcastDetailContent: View {
    let content: PodcastContent
    let refresh: @MainActor () async -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.itemActionHandler) private var handler
    @Environment(AlertCenter.self) private var alerts
    @Environment(PlayerPresentation.self) private var presentation

    @State private var dominantColor: HearthRGBColor?
    @State private var settings: EpisodeListSettings
    @State private var isConfiguring = false

    private static let previewCount = 15

    init(content: PodcastContent, refresh: @escaping @MainActor () async -> Void) {
        self.content = content
        self.refresh = refresh
        _settings = State(initialValue: HearthData.shared.itemSettings.episodeListSettings(for: content.podcast))
    }

    private var podcast: Podcast { content.podcast }
    private var seasons: [String] { HearthData.shared.itemSettings.seasons(in: content.episodes) }
    private var filtered: [Episode] { HearthData.shared.itemSettings.apply(settings, to: content.episodes) }

    /// Episode the header's play button starts: the first one in the user's order that isn't finished.
    private var nextEpisode: Episode? {
        var unfinished = settings
        unfinished.filter = .notFinished
        unfinished.downloadedOnly = false
        unfinished.season = nil
        let ordered = HearthData.shared.itemSettings.apply(unfinished, to: content.episodes)
        return ordered.first ?? EpisodeSorting.latest(content.episodes)
    }

    var body: some View {
        let episodes = filtered
        List {
            PodcastHeader(podcast: podcast, nextEpisode: nextEpisode, color: dominantColor)
                .detailPlainRow(insets: EdgeInsets(top: 0, leading: 20, bottom: 20, trailing: 20))

            Section {
                Group {
                    HStack(alignment: .firstTextBaseline) {
                        DetailSectionTitle(title: String(localized: "Episodes", table: "Detail"))
                        Spacer()
                        if seasons.count >= 2 {
                            SeasonMenu(seasons: seasons, selection: $settings.season)
                        }
                    }
                }
                .detailPlainRow(insets: EdgeInsets(top: 18, leading: 20, bottom: 6, trailing: 20))
                if episodes.isEmpty {
                    Text("No episodes match the current filter.", tableName: "Detail")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                } else {
                    ForEach(episodes.prefix(Self.previewCount)) { episode in
                        NavigationLink(value: NavigationDestination.item(episode.id)) {
                            EpisodeRow(episode: episode, showsCover: false, descriptionLines: 2, context: .podcastPage)
                        }
                        .itemActions(for: .episode(episode), context: .podcastPage)
                    }
                }
                NavigationLink(value: NavigationDestination.allEpisodes(podcast: podcast.id)) {
                    HStack {
                        Text("All Episodes", tableName: "Detail")
                            .font(.headline)
                        Spacer()
                        Text(content.episodes.count, format: .number)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            PodcastInfoSection(podcast: podcast)
        }
        .listStyle(.plain)
        .heroBackground(color: dominantColor, height: sizeClass == .compact ? 640 : 520, solid: true)
        .detailNavigationTitle(podcast.name, threshold: 380)
        .environment(\.itemActionHandler, handler.withPlaybackOrigin(.podcast(podcast.id), alerts: alerts, presentation: presentation))
        .refreshable { await refresh() }
        .task(id: podcast.id) {
            let color = await HearthData.shared.images.dominantColor(for: podcast.id)
            withAnimation(.smooth) { dominantColor = color }
        }
        .onChange(of: settings) { _, value in
            HearthData.shared.itemSettings.setEpisodeListSettings(value, for: podcast.id)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isConfiguring = true
                } label: {
                    Label(String(localized: "Configure", table: "Detail"), systemImage: "slider.horizontal.3")
                }
                EpisodeListOptionsButton(settings: $settings)
            }
        }
        .sheet(isPresented: $isConfiguring) {
            ConfigureSheet(id: podcast.id, title: podcast.name)
        }
    }
}

enum EpisodeSorting {
    static func latest(_ episodes: [Episode]) -> Episode? {
        episodes.max { ($0.publishedAt ?? $0.addedAt ?? .distantPast) < ($1.publishedAt ?? $1.addedAt ?? .distantPast) }
    }
}

// MARK: - Header

private struct PodcastHeader: View {
    let podcast: Podcast
    let nextEpisode: Episode?
    let color: HearthRGBColor?

    var body: some View {
        VStack(spacing: 12) {
            ItemImage(id: podcast.id, size: .large, cornerRadius: 16)
                .frame(width: 240, height: 240)
                .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
                .padding(.top, 8)
            VStack(spacing: 4) {
                Text(podcast.name)
                    .hearthTitle(.title2)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .accessibilityAddTraits(.isHeader)
                if let authors = podcast.authorLine {
                    Text(authors)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            if let nextEpisode {
                VStack(spacing: 4) {
                    PlayButton(item: .episode(nextEpisode), style: .large, tint: color?.headerButtonColor)
                        .frame(maxWidth: 360)
                    Text(nextEpisode.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 4)
            }
            DescriptionView(html: podcast.descriptionHTML, collapsedLines: 3, expansion: .sheet(title: podcast.name))
            Text(statsLine)
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .modifier(OptionalColorScheme(scheme: color?.headerColorScheme))
    }


    private var statsLine: String {
        var parts: [String?] = [HearthFormat.episodeCount(podcast.episodeCount)]
        if podcast.explicit {
            parts.append(String(localized: "Explicit", table: "Detail"))
        }
        parts.append(podcast.publishingType == .serial ? String(localized: "Serial", table: "Detail") : String(localized: "Episodic", table: "Detail"))
        parts.append(podcast.genres.prefix(3).joined(separator: ", "))
        return HearthFormat.joined(parts)
    }
}

/// Applies a color scheme only when known (falls back to the environment's).
struct OptionalColorScheme: ViewModifier {
    let scheme: ColorScheme?
    @Environment(\.colorScheme) private var inherited

    func body(content: Content) -> some View {
        content.environment(\.colorScheme, scheme ?? inherited)
    }
}

// MARK: - Info

private struct PodcastInfoSection: View {
    let podcast: Podcast

    var body: some View {
        Section {
            Group {
                DetailSectionTitle(title: String(localized: "Information", table: "Detail"))
            }
            .detailPlainRow(insets: EdgeInsets(top: 18, leading: 20, bottom: 6, trailing: 20))
            if let language = podcast.language, !language.isEmpty {
                DetailInfoRow(label: String(localized: "Language", table: "Detail"), value: Locale.current.localizedString(forLanguageCode: language) ?? language)
            }
            if !podcast.genres.isEmpty {
                DetailInfoRow(label: String(localized: "Genres", table: "Detail"), value: podcast.genres.joined(separator: ", "))
            }
            if let released = podcast.released, !released.isEmpty {
                DetailInfoRow(label: String(localized: "Released", table: "Detail"), value: released)
            }
            if let added = podcast.addedAt {
                DetailInfoRow(label: String(localized: "Added", table: "Detail"), value: added.formatted(date: .long, time: .omitted))
            }
            if let feed = podcast.feedURL {
                Link(destination: feed) {
                    Label(String(localized: "RSS Feed", table: "Detail"), systemImage: "dot.radiowaves.up.forward")
                        .font(.subheadline)
                }
            }
        }
    }
}
