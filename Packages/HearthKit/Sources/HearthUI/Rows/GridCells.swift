import HearthData
import HearthModel
import SwiftUI

/// Grid cell: cover with status overlay, title and authors.
public struct AudiobookGridCell: View {
    let audiobook: Audiobook
    let showsText: Bool

    public init(audiobook: Audiobook, showsText: Bool = true) {
        self.audiobook = audiobook
        self.showsText = showsText
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ItemCover(id: audiobook.id, size: .small, cornerRadius: 10)
            if showsText {
                VStack(alignment: .leading, spacing: 1) {
                    Text(audiobook.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if let authors = audiobook.authorLine {
                        Text(authors)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .contentShape(.rect)
        #if os(iOS)
        .hoverEffect(.lift)
        #endif
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Audiobook: \(audiobook.name)", bundle: .module))
        .accessibilityValue(ItemStatus.of(audiobook.id).accessibilityValue)
    }
}

/// Grid cell for a podcast with an unplayed-count badge.
public struct PodcastGridCell: View {
    let podcast: Podcast

    public init(podcast: Podcast) {
        self.podcast = podcast
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ItemCover(id: podcast.id, size: .small, cornerRadius: 10, showsStatus: false)
                .overlay(alignment: .topTrailing) {
                    if let unplayed = podcast.incompleteEpisodeCount, unplayed > 0 {
                        Text(unplayed, format: .number)
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.tint, in: .capsule)
                            .padding(6)
                            .accessibilityHidden(true)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(podcast.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let authors = podcast.authorLine {
                    Text(authors)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(.rect)
        #if os(iOS)
        .hoverEffect(.lift)
        #endif
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Podcast: \(podcast.name)", bundle: .module))
        .accessibilityValue(podcast.incompleteEpisodeCount.map { HearthFormat.unplayedCount($0) } ?? "")
    }
}

/// Grid cell for a series: cover collage (1 cover / 2–3 diagonal / 2×2), name, "N books".
public struct SeriesGridCell: View {
    let series: Series

    public init(series: Series) {
        self.series = series
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SeriesCollage(covers: series.audiobooks.map(\.id), fallback: series.id)
            VStack(alignment: .leading, spacing: 1) {
                Text(series.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(HearthFormat.bookCount(series.bookCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
        #if os(iOS)
        .hoverEffect(.lift)
        #endif
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Series: \(series.name)", bundle: .module))
        .accessibilityValue(HearthFormat.bookCount(series.bookCount))
    }
}

/// Square series collage.
public struct SeriesCollage: View {
    let covers: [ItemIdentifier]
    let fallback: ItemIdentifier

    public init(covers: [ItemIdentifier], fallback: ItemIdentifier) {
        self.covers = covers
        self.fallback = fallback
    }

    public var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    let side = proxy.size.width
                    switch covers.count {
                    case 0:
                        ItemImage(id: fallback, size: .small, cornerRadius: 10)
                    case 1:
                        ItemImage(id: covers[0], size: .small, cornerRadius: 10)
                    case 2, 3:
                        let count = covers.count
                        let coverSide = side * (count == 2 ? 0.72 : 0.62)
                        let step = (side - coverSide) / CGFloat(count - 1)
                        ZStack(alignment: .topLeading) {
                            ForEach(Array(covers.prefix(3).enumerated()), id: \.offset) { index, id in
                                ItemImage(id: id, size: .tiny, cornerRadius: 8)
                                    .frame(width: coverSide, height: coverSide)
                                    .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                                    .offset(x: step * CGFloat(index), y: step * CGFloat(index))
                                    .zIndex(Double(index))
                            }
                        }
                        .frame(width: side, height: side, alignment: .topLeading)
                    default:
                        let spacing: CGFloat = 3
                        let cell = (side - spacing) / 2
                        VStack(spacing: spacing) {
                            HStack(spacing: spacing) {
                                ItemImage(id: covers[0], size: .tiny, cornerRadius: 0).frame(width: cell, height: cell)
                                ItemImage(id: covers[1], size: .tiny, cornerRadius: 0).frame(width: cell, height: cell)
                            }
                            HStack(spacing: spacing) {
                                ItemImage(id: covers[2], size: .tiny, cornerRadius: 0).frame(width: cell, height: cell)
                                ItemImage(id: covers[3], size: .tiny, cornerRadius: 0).frame(width: cell, height: cell)
                            }
                        }
                        .clipShape(.rect(cornerRadius: 10, style: .continuous))
                    }
                }
            }
            .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Grid cells") {
    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 16) {
            AudiobookGridCell(audiobook: PreviewFixtures.audiobook)
            PodcastGridCell(podcast: PreviewFixtures.podcast)
            SeriesGridCell(series: PreviewFixtures.series)
            SeriesGridCell(series: PreviewFixtures.seriesLarge)
        }
        .padding()
    }
    .tint(TintColor.hearth.color)
}
#endif
