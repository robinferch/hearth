import HearthData
import HearthModel
import SwiftUI

/// List row for a series with fanned covers and "N books".
public struct SeriesRow: View {
    let series: Series

    public init(series: Series) {
        self.series = series
    }

    public var body: some View {
        HStack(spacing: 14) {
            FannedCovers(ids: series.audiobooks.map(\.id), fallback: series.id, coverSize: 60)
                .frame(width: 96, height: 72)
            VStack(alignment: .leading, spacing: 3) {
                Text(series.name)
                    .font(.headline)
                    .lineLimit(2)
                Text(HearthFormat.joined([HearthFormat.bookCount(series.bookCount), series.authorsLine]))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let total = series.totalDuration, total > 0 {
                    Text(HearthFormat.duration(total))
                        .font(.caption.smallCaps())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Series: \(series.name)", bundle: .module))
        .accessibilityValue(HearthFormat.bookCount(series.bookCount))
    }
}

private extension Series {
    var authorsLine: String? {
        authors.isEmpty ? nil : authors.prefix(2).formatted(.list(type: .and, width: .short))
    }
}

/// Up to `limit` covers fanned out horizontally (used by series rows and headers).
public struct FannedCovers: View {
    let ids: [ItemIdentifier]
    let fallback: ItemIdentifier?
    let coverSize: CGFloat
    let limit: Int

    public init(ids: [ItemIdentifier], fallback: ItemIdentifier? = nil, coverSize: CGFloat, limit: Int = 3) {
        self.ids = ids
        self.fallback = fallback
        self.coverSize = coverSize
        self.limit = limit
    }

    public var body: some View {
        let covers = Array(ids.prefix(limit))
        let shown: [ItemIdentifier?] = covers.isEmpty ? [fallback] : covers
        let count = shown.count
        ZStack {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, id in
                let center = CGFloat(count - 1) / 2
                let position = CGFloat(index) - center
                ItemImage(id: id, size: .tiny, cornerRadius: 6)
                    .frame(width: coverSize * (1 - abs(position) * 0.12), height: coverSize * (1 - abs(position) * 0.12))
                    .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
                    .rotationEffect(.degrees(Double(position) * 6))
                    .offset(x: position * coverSize * 0.32)
                    .zIndex(-abs(Double(position)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Row for an author (round avatar) or narrator (symbol), with "N books".
public struct PersonRow: View {
    let person: Person
    let avatarSize: CGFloat

    public init(person: Person, avatarSize: CGFloat = 52) {
        self.person = person
        self.avatarSize = avatarSize
    }

    public var body: some View {
        HStack(spacing: 12) {
            if person.id.kind == .narrator {
                Image(systemName: "waveform")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: avatarSize, height: avatarSize)
                    .background(.quaternary, in: .circle)
                    .accessibilityHidden(true)
            } else {
                ItemImage(id: person.id, size: .tiny)
                    .frame(width: avatarSize, height: avatarSize)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(HearthFormat.bookCount(person.bookCount))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "\(person.id.kind.localizedName): \(person.name)", bundle: .module))
        .accessibilityValue(HearthFormat.bookCount(person.bookCount))
    }
}

/// Round author avatar with name below (home "Authors" row, author grids).
public struct PersonAvatarCell: View {
    let person: Person

    public init(person: Person) {
        self.person = person
    }

    public var body: some View {
        VStack(spacing: 6) {
            ItemImage(id: person.id, size: .small)
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            Text(person.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(HearthFormat.bookCount(person.bookCount))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Author: \(person.name)", bundle: .module))
    }
}

/// Row for a collection or playlist: 68 pt image (cover or 2×2 mosaic), name, count.
public struct CollectionRow: View {
    let collection: ItemCollection

    public init(collection: ItemCollection) {
        self.collection = collection
    }

    public var body: some View {
        HStack(spacing: 12) {
            CoverMosaic(ids: collection.items.map(\.id), fallback: collection.id)
                .frame(width: 68, height: 68)
            VStack(alignment: .leading, spacing: 2) {
                Text(collection.name)
                    .font(.headline)
                    .lineLimit(2)
                Text(HearthFormat.itemCount(collection.items.count))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let description = HearthFormat.plainText(fromHTML: collection.descriptionHTML) {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "\(collection.id.kind.localizedName): \(collection.name)", bundle: .module))
        .accessibilityValue(HearthFormat.itemCount(collection.items.count))
    }
}

/// A single cover, or a 2×2 mosaic when there are 4+ distinct covers.
public struct CoverMosaic: View {
    let ids: [ItemIdentifier]
    let fallback: ItemIdentifier?
    let cornerRadius: CGFloat

    public init(ids: [ItemIdentifier], fallback: ItemIdentifier? = nil, cornerRadius: CGFloat = 8) {
        self.ids = ids
        self.fallback = fallback
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        // Episodes of the same podcast share a cover; use distinct library items for the mosaic.
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0.apiItemID).inserted }
        return Group {
            if unique.count >= 4 {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        Grid(horizontalSpacing: 1, verticalSpacing: 1) {
                            GridRow {
                                ItemImage(id: unique[0], size: .tiny, cornerRadius: 0)
                                ItemImage(id: unique[1], size: .tiny, cornerRadius: 0)
                            }
                            GridRow {
                                ItemImage(id: unique[2], size: .tiny, cornerRadius: 0)
                                ItemImage(id: unique[3], size: .tiny, cornerRadius: 0)
                            }
                        }
                    }
                    .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
            } else {
                ItemImage(id: unique.first ?? fallback, size: .tiny, cornerRadius: cornerRadius, placeholderSymbol: fallback?.kind.systemImage)
            }
        }
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Grouping rows") {
    List {
        SeriesRow(series: PreviewFixtures.seriesLarge)
        PersonRow(person: PreviewFixtures.author)
        PersonRow(person: PreviewFixtures.narrator)
        CollectionRow(collection: PreviewFixtures.collection)
    }
}
#endif
