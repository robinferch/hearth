import HearthData
import HearthModel
import SwiftUI

/// List row for a podcast episode: optional 92 pt cover, title (2 lines), description (1–3 lines) and an
/// action line with an inline play pill, trailer/bonus icon, date, download state and an ellipsis menu.
public struct EpisodeRow: View {
    let episode: Episode
    let showsCover: Bool
    let descriptionLines: Int
    let context: ItemActionContext

    public init(episode: Episode, showsCover: Bool = true, descriptionLines: Int = 2, context: ItemActionContext = .standard) {
        self.episode = episode
        self.showsCover = showsCover
        self.descriptionLines = descriptionLines
        self.context = context
    }

    public var body: some View {
        let status = ItemStatus.of(episode.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                if showsCover {
                    ItemImage(id: episode.id, size: .small, cornerRadius: 8)
                        .frame(width: 92, height: 92)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if !showsCover, let podcastLine = metadataLine {
                        Text(podcastLine)
                            .font(.caption.smallCaps())
                            .foregroundStyle(.secondary)
                    } else if showsCover {
                        Text(episode.podcastName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(episode.name)
                        .font(.headline)
                        .lineLimit(2)
                    if let description = HearthFormat.plainText(fromHTML: episode.descriptionHTML) {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(showsCover ? max(1, descriptionLines - 1) : descriptionLines)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            EpisodeActionLine(episode: episode, status: status, context: context)
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Episode: \(episode.name)", bundle: .module))
        .accessibilityValue(status.accessibilityValue)
    }

    private var metadataLine: String? {
        let value = HearthFormat.joined([
            episode.season.map { String(localized: "Season \($0)", bundle: .module) },
            episode.episode.map { String(localized: "Episode \($0)", bundle: .module) },
        ])
        return value.isEmpty ? nil : value
    }
}

/// "▶︎ 32m • 🅣 • Oct 3 • ⬇︎ • …" line shared by episode rows and cards.
public struct EpisodeActionLine: View {
    let episode: Episode
    let status: ItemStatus
    let context: ItemActionContext

    public init(episode: Episode, status: ItemStatus, context: ItemActionContext = .standard) {
        self.episode = episode
        self.status = status
        self.context = context
    }

    public var body: some View {
        HStack(spacing: 8) {
            PlayButton(item: .episode(episode), style: .inline)
            switch episode.type {
            case .trailer:
                Image(systemName: "movieclapper")
                    .accessibilityLabel(loc("Trailer"))
            case .bonus:
                Image(systemName: "gift")
                    .accessibilityLabel(loc("Bonus"))
            case .full:
                EmptyView()
            }
            if let date = episode.publishedAt {
                Text(HearthFormat.releaseDate(date))
                    .lineLimit(1)
            }
            if status.isDownloading {
                DownloadProgressRing(progress: status.downloadProgress, lineWidth: 1.5)
                    .frame(width: 13, height: 13)
            } else if status.isDownloaded {
                Image(systemName: "arrow.down.circle")
                    .accessibilityLabel(loc("Downloaded"))
            }
            Spacer(minLength: 0)
            #if !os(watchOS)
            Menu {
                ItemContextMenu(item: .episode(episode), context: context)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 24)
                    .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel(loc("More"))
            #endif
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

#if DEBUG
#Preview("Episode row") {
    List {
        EpisodeRow(episode: PreviewFixtures.episode)
        EpisodeRow(episode: PreviewFixtures.episode, showsCover: false)
    }
    .tint(TintColor.hearth.color)
}
#endif
