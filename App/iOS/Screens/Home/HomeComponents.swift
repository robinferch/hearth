import HearthData
import HearthModel
import HearthUI
import SwiftUI

/// Localized titles for known audiobookshelf shelf ids.
enum HomeRowTitle {
    static func title(for row: HomeRow) -> String {
        switch row.id {
        case "continue-listening": String(localized: "Continue Listening")
        case "continue-series": String(localized: "Continue Series")
        case "continue-reading": String(localized: "Continue Reading")
        case "recently-added": String(localized: "Recently Added")
        case "recent-series": String(localized: "Recent Series")
        case "listen-again": String(localized: "Listen Again")
        case "read-again": String(localized: "Read Again")
        case "discover": String(localized: "Discover")
        case "newest-authors": String(localized: "Newest Authors")
        case "newest-episodes": String(localized: "Newest Episodes")
        case "episodes-recently-added": String(localized: "Recently Added Episodes")
        case "downloaded": String(localized: "Downloaded")
        default: row.label
        }
    }
}

/// Width of a shelf cell for the available container width.
private func shelfCellWidth(container: CGFloat, compact: Bool, wide: Bool = false) -> CGFloat {
    let spacing: CGFloat = 14
    let visible: CGFloat = compact ? (wide ? 1.12 : 2.35) : (wide ? 2.2 : 5.3)
    return max(100, (container - spacing * (visible.rounded(.down))) / visible)
}

/// A horizontal shelf with a header (chevron opens the full grid when there are more than 5 items).
struct HomeRowSection: View {
    let row: HomeRow
    let library: LibraryIdentifier

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(row.items) { item in
                        ShelfItemCell(item: item)
                            .containerRelativeFrame(.horizontal) { length, _ in
                                shelfCellWidth(container: length, compact: sizeClass == .compact)
                            }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 20, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private var header: some View {
        let title = HomeRowTitle.title(for: row)
        if row.items.count > 5 {
            NavigationLink(value: NavigationDestination.homeRow(row, library: library)) {
                HStack(spacing: 4) {
                    Text(title)
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .font(.title3.weight(.semibold))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHint("Shows all items")
        } else {
            Text(title)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 20)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// A cell in a shelf or grid, linking to the item and offering its context menu.
struct ShelfItemCell: View {
    let item: AnyItem

    var body: some View {
        NavigationLink(value: NavigationDestination.item(item.id)) {
            content
        }
        .buttonStyle(.plain)
        .modifier(ShelfActions(item: item))
        .draggable(item.id.description)
    }

    @ViewBuilder
    private var content: some View {
        switch item {
        case .audiobook(let book):
            AudiobookGridCell(audiobook: book)
        case .series(let series):
            SeriesGridCell(series: series)
        case .person(let person):
            PersonAvatarCell(person: person)
        case .podcast(let podcast):
            PodcastGridCell(podcast: podcast)
        case .episode(let episode):
            EpisodeShelfCell(episode: episode)
        case .collection(let collection):
            VStack(alignment: .leading, spacing: 6) {
                CoverMosaic(ids: collection.items.map(\.id), fallback: collection.id, cornerRadius: 10)
                Text(collection.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(HearthFormat.itemCount(collection.items.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ShelfActions: ViewModifier {
    let item: AnyItem

    func body(content: Content) -> some View {
        if let playable = item.playable {
            content.itemActions(for: playable, swipeActions: false)
        } else {
            content.itemActions(for: item)
        }
    }
}

/// Episode in a shelf: cover, date, title and inline play pill.
struct EpisodeShelfCell: View {
    let episode: Episode

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ItemCover(id: episode.id, size: .small, cornerRadius: 10)
            if let date = episode.publishedAt {
                Text(HearthFormat.releaseDate(date))
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
            }
            Text(episode.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(2, reservesSpace: true)
            PlayButton(item: .episode(episode), style: .inline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Episode: \(episode.name)")
    }
}

/// Full grid of a home shelf.
struct HomeRowGridView: View {
    let row: HomeRow
    let library: LibraryIdentifier

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .compact ? 150 : 180), spacing: 16, alignment: .top)], spacing: 22) {
                ForEach(row.items) { item in
                    ShelfItemCell(item: item)
                }
            }
            .padding(20)
        }
        .navigationTitle(HomeRowTitle.title(for: row))
    }
}
