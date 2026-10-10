import HearthData
import HearthModel
import SwiftUI

/// Compact row used by search results, Listen Now and collections: caption (date / duration),
/// title, subtitle and a trailing progress ring / download ring / unplayed count.
public struct CompactItemRow: View {
    let item: AnyItem
    let coverSize: CGFloat
    let showsStatus: Bool

    public init(item: AnyItem, coverSize: CGFloat = 56, showsStatus: Bool = true) {
        self.item = item
        self.coverSize = coverSize
        self.showsStatus = showsStatus
    }

    public init(item: AnyPlayableItem, coverSize: CGFloat = 56, showsStatus: Bool = true) {
        self.init(item: AnyItem(item), coverSize: coverSize, showsStatus: showsStatus)
    }

    private var caption: String? {
        let value: String = switch item {
        case .audiobook(let book):
            HearthFormat.joined([book.series.first?.formatted, HearthFormat.duration(book.duration)])
        case .episode(let episode):
            HearthFormat.joined([episode.publishedAt.map { HearthFormat.releaseDate($0) }, HearthFormat.duration(episode.duration)])
        case .podcast(let podcast):
            HearthFormat.episodeCount(podcast.episodeCount)
        case .series, .person, .collection:
            ""
        }
        return value.isEmpty ? nil : value
    }

    public var body: some View {
        HStack(spacing: 12) {
            ItemImage(id: item.id, size: .tiny, cornerRadius: 6)
                .frame(width: coverSize, height: coverSize)
            VStack(alignment: .leading, spacing: 2) {
                if let caption {
                    Text(caption)
                        .font(.caption.smallCaps())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(item.name)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsStatus {
                trailing
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "\(item.id.kind.localizedName): \(item.name)", bundle: .module))
        .accessibilityValue(item.playable.map { ItemStatus.of($0.id).accessibilityValue } ?? "")
    }

    @ViewBuilder
    private var trailing: some View {
        switch item {
        case .audiobook, .episode:
            ItemStatusIndicator(id: item.id)
        case .podcast(let podcast):
            if let unplayed = podcast.incompleteEpisodeCount, unplayed > 0 {
                Text(unplayed, format: .number)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.tint.opacity(0.15), in: .capsule)
                    .foregroundStyle(.tint)
            }
        default:
            EmptyView()
        }
    }
}

#if DEBUG
#Preview("Compact rows") {
    List {
        CompactItemRow(item: AnyItem.audiobook(PreviewFixtures.audiobook))
        CompactItemRow(item: AnyItem.episode(PreviewFixtures.episode))
        CompactItemRow(item: AnyItem.podcast(PreviewFixtures.podcast))
    }
}
#endif
