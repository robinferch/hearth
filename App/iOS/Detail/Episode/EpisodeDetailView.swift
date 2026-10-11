import HearthAPI
import HearthData
import HearthModel
import HearthPlayback
import HearthUI
import SwiftUI

/// Episode page: gradient header, description with tappable timestamps, info list (editable episode type) and
/// the listening timeline.
struct EpisodeDetailView: View {
    let id: ItemIdentifier

    @State private var loader: DetailLoader<Episode>

    init(id: ItemIdentifier) {
        self.id = id
        _loader = State(initialValue: DetailLoader {
            guard case .episode(let episode) = try await HearthData.shared.items.item(id) else {
                throw APIError.notFound
            }
            return episode
        })
    }

    var body: some View {
        LoadStateView(loader.state, retry: { await loader.reload() }) { episode in
            EpisodeDetailContent(episode: episode, loader: loader)
        }
        .itemUserActivity(id, title: loader.value?.name)
        .task {
            if loader.value == nil {
                await loader.reload()
            }
        }
    }
}

private struct EpisodeDetailContent: View {
    let episode: Episode
    let loader: DetailLoader<Episode>

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.itemActionHandler) private var handler
    @Environment(AlertCenter.self) private var alerts
    @Environment(PlayerPresentation.self) private var presentation

    @State private var dominantColor: HearthRGBColor?
    @State private var updatingType = false

    var body: some View {
        List {
            EpisodeHeader(episode: episode, color: dominantColor)
                .detailPlainRow(insets: EdgeInsets(top: 0, leading: 20, bottom: 20, trailing: 20))

            if episode.descriptionHTML?.isEmpty == false {
                DescriptionView(html: episode.descriptionHTML, collapsedLines: 12, linkTimestamps: true, seekItemID: episode.id)
                    .detailPlainRow(insets: EdgeInsets(top: 4, leading: 20, bottom: 16, trailing: 20))
            }

            Section {
                Group {
                    DetailSectionTitle(title: String(localized: "Information", table: "Detail"))
                }
                .detailPlainRow(insets: EdgeInsets(top: 18, leading: 20, bottom: 6, trailing: 20))
                if let podcastID = episode.id.podcastIdentifier {
                    NavigationLink(value: NavigationDestination.item(podcastID)) {
                        DetailInfoRow(label: String(localized: "Podcast", table: "Detail"), value: episode.podcastName)
                    }
                }
                if let author = episode.authorLine {
                    DetailInfoRow(label: String(localized: "Author", table: "Detail"), value: author)
                }
                if let number = episode.episode, !number.isEmpty {
                    DetailInfoRow(label: String(localized: "Episode", table: "Detail"), value: number)
                }
                if let season = episode.season, !season.isEmpty {
                    DetailInfoRow(label: String(localized: "Season", table: "Detail"), value: season)
                }
                if let published = episode.publishedAt {
                    DetailInfoRow(label: String(localized: "Released", table: "Detail"), value: published.formatted(date: .long, time: .shortened))
                }
                if episode.duration > 0 {
                    DetailInfoRow(label: String(localized: "Duration", table: "Detail"), value: HearthFormat.duration(episode.duration))
                }
                if let size = episode.size, size > 0 {
                    DetailInfoRow(label: String(localized: "Size", table: "Detail"), value: HearthFormat.bytes(size))
                }
                episodeTypeRow
            }
            .listRowBackground(Color.clear)

            TimelineSection(id: episode.id, released: episode.publishedAt, added: episode.addedAt)
        }
        .listStyle(.plain)
        .heroBackground(color: dominantColor, height: sizeClass == .compact ? 620 : 540, solid: true)
        .detailNavigationTitle(episode.name, threshold: 340)
        .refreshable {
            HearthData.shared.items.invalidate(episode.id)
            await loader.reload()
        }
        .task(id: episode.id) {
            let color = await HearthData.shared.images.dominantColor(for: episode.id)
            withAnimation(.smooth) { dominantColor = color }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                DownloadToolbarButton(id: episode.id)
                PlayableMoreMenu(item: .episode(episode))
            }
        }
    }

    private var episodeTypeRow: some View {
        Picker(selection: Binding(get: { episode.type }, set: { updateType($0) })) {
            ForEach(Episode.EpisodeType.allCases, id: \.self) { type in
                Text(type.title).tag(type)
            }
        } label: {
            HStack {
                Text("Episode Type", tableName: "Detail")
                if updatingType {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .pickerStyle(.menu)
        .font(.subheadline)
        .disabled(updatingType || HearthData.shared.connections.isOffline)
    }

    private func updateType(_ type: Episode.EpisodeType) {
        guard type != episode.type else { return }
        updatingType = true
        Task {
            defer { updatingType = false }
            do {
                try await Client.for(episode.id.connectionID).updateEpisodeType(episode.id, type: type)
                HearthData.shared.items.invalidate(episode.id)
                loader.update { $0.type = type }
                alerts.succeed()
            } catch {
                alerts.fail(error)
            }
        }
    }
}

extension Episode.EpisodeType {
    var title: String {
        switch self {
        case .full: String(localized: "Full", table: "Detail")
        case .trailer: String(localized: "Trailer", table: "Detail")
        case .bonus: String(localized: "Bonus", table: "Detail")
        }
    }
}

private struct EpisodeHeader: View {
    let episode: Episode
    let color: HearthRGBColor?

    var body: some View {
        VStack(spacing: 10) {
            ItemImage(id: episode.id, size: .regular, cornerRadius: 14)
                .frame(width: 180, height: 180)
                .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
                .padding(.top, 8)
            Text(HearthFormat.joined([episode.publishedAt.map { HearthFormat.releaseDate($0) }, HearthFormat.duration(episode.duration)]))
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
            Text(episode.name)
                .hearthTitle(.title2)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .accessibilityAddTraits(.isHeader)
            if let podcastID = episode.id.podcastIdentifier {
                DetailLink(value: .item(podcastID)) {
                    HStack(spacing: 4) {
                        Text(episode.podcastName)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                    }
                    .font(.headline)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            if episode.type != .full {
                Label(episode.type.title, systemImage: episode.type == .trailer ? "movieclapper" : "gift")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.secondary.opacity(0.18), in: .capsule)
            }
            PlayButton(item: .episode(episode), style: .large, tint: color?.headerButtonColor)
                .frame(maxWidth: 360)
                .padding(.top, 6)
                .contextMenu {
                    ItemContextMenu(item: .episode(episode))
                }
        }
        .frame(maxWidth: .infinity)
        .modifier(OptionalColorScheme(scheme: color?.headerColorScheme))
    }

}
