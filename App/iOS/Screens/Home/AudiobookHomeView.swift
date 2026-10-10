import HearthData
import HearthModel
import HearthUI
import SwiftUI

/// Personalized shelves of an audiobook library.
struct AudiobookHomeView: View {
    let library: Library

    @State private var state: LoadState<[HomeRow]> = .loading

    private var settings: AppSettings { .shared }
    private var data: HearthData { .shared }

    var body: some View {
        Group {
            switch state {
            case .loading:
                LoadingView()
            case .failed(let error):
                ErrorView(message: error.userMessage, retry: load)
            case .loaded(let rows):
                let visible = visibleRows(rows)
                if visible.isEmpty {
                    EmptyStateView(title: String(localized: "Nothing Here Yet"), systemImage: "books.vertical", message: String(localized: "Add audiobooks to this library on your server."))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 28) {
                            ForEach(visible) { row in
                                HomeRowSection(row: row, library: library.id)
                            }
                        }
                        .padding(.vertical, 12)
                    }
                }
            }
        }
        .navigationTitle(library.name)
        .refreshable {
            await HearthData.shared.refresh()
            await load()
        }
        .task(id: library.id) {
            await load()
        }
    }

    /// Applies the user's home settings and adds the local "Downloaded" shelf.
    private func visibleRows(_ rows: [HomeRow]) -> [HomeRow] {
        var result: [HomeRow] = rows.compactMap { row in
            if settings.hideDiscoverRow, row.id == "discover" {
                return nil
            }
            let isAuthorRow = row.items.allSatisfy { if case .person = $0 { true } else { false } }
            if isAuthorRow, !settings.showAuthorsRow {
                return nil
            }
            var row = row
            if row.id == "continue-listening" {
                row.items = row.items.filter { item in
                    data.progress.progress(for: item.id)?.hideFromContinueListening != true
                }
            }
            return row.items.isEmpty ? nil : row
        }
        let downloaded = data.downloads.downloadedAudiobooks(in: library.id)
        if !downloaded.isEmpty {
            let row = HomeRow(id: "downloaded", label: String(localized: "Downloaded"), items: downloaded.map { .audiobook($0) })
            let insertIndex = result.firstIndex { $0.id == "continue-listening" }.map { $0 + 1 } ?? 0
            result.insert(row, at: min(insertIndex, result.count))
        }
        return result
    }

    private func load() async {
        if state.value == nil {
            state = .loading
        }
        do {
            let rows = try await Client.for(library.connectionID).home(library: library)
            state = .loaded(rows)
        } catch {
            if state.value == nil {
                state = .failed(error)
            }
        }
    }
}

/// Podcast library home: featured "continue listening" cards, episode grids and podcast shelves.
struct PodcastHomeView: View {
    let library: Library

    @State private var state: LoadState<[HomeRow]> = .loading

    var body: some View {
        Group {
            switch state {
            case .loading:
                LoadingView(systemImage: "antenna.radiowaves.left.and.right")
            case .failed(let error):
                ErrorView(message: error.userMessage, retry: load)
            case .loaded(let rows):
                if rows.isEmpty {
                    EmptyStateView(title: String(localized: "Nothing Here Yet"), systemImage: "antenna.radiowaves.left.and.right", message: String(localized: "Add podcasts to this library on your server."))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 28) {
                            ForEach(rows) { row in
                                rowView(row)
                            }
                        }
                        .padding(.vertical, 12)
                    }
                }
            }
        }
        .navigationTitle(library.name)
        .refreshable {
            await HearthData.shared.refresh()
            await load()
        }
        .task(id: library.id) {
            await load()
        }
    }

    @ViewBuilder
    private func rowView(_ row: HomeRow) -> some View {
        let episodes: [Episode] = row.items.compactMap { if case .episode(let episode) = $0 { episode } else { nil } }
        if row.id == "continue-listening", !episodes.isEmpty {
            FeaturedEpisodesCarousel(title: HomeRowTitle.title(for: row), episodes: episodes)
        } else if episodes.count == row.items.count, !episodes.isEmpty {
            EpisodeGridShelf(row: row, episodes: episodes, library: library.id)
        } else {
            HomeRowSection(row: row, library: library.id)
        }
    }

    private func load() async {
        if state.value == nil {
            state = .loading
        }
        do {
            let rows = try await Client.for(library.connectionID).home(library: library)
            state = .loaded(rows.filter { !$0.items.isEmpty })
        } catch {
            if state.value == nil {
                state = .failed(error)
            }
        }
    }
}

/// Tall paging cards for in-progress episodes.
struct FeaturedEpisodesCarousel: View {
    let title: String
    let episodes: [Episode]

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 20)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 14) {
                    ForEach(episodes) { episode in
                        NavigationLink(value: NavigationDestination.item(episode.id)) {
                            FeaturedEpisodeCard(episode: episode)
                        }
                        .buttonStyle(.plain)
                        .itemActions(for: .episode(episode), swipeActions: false)
                        .containerRelativeFrame(.horizontal) { length, _ in
                            sizeClass == .compact ? length - 56 : min(420, length / 2.3)
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
}

/// Card with blurred cover background, gradient, date, title, description and a glass play pill.
struct FeaturedEpisodeCard: View {
    let episode: Episode

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ItemImage(id: episode.id, size: .regular, cornerRadius: 0)
                .scaleEffect(1.4)
                .blur(radius: 30)
                .overlay(.black.opacity(0.15))
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 8) {
                ItemImage(id: episode.id, size: .small, cornerRadius: 10)
                    .frame(width: 92, height: 92)
                    .shadow(radius: 8, y: 4)
                Spacer(minLength: 0)
                if let date = episode.publishedAt {
                    Text(HearthFormat.releaseDate(date))
                        .font(.caption.smallCaps().weight(.semibold))
                        .foregroundStyle(.white.opacity(0.75))
                }
                Text(episode.name)
                    .hearthTitle(.title3)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let description = HearthFormat.plainText(fromHTML: episode.descriptionHTML) {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(2)
                }
                PlayButton(item: .episode(episode), style: .medium)
            }
            .padding(16)
        }
        .frame(height: 340)
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .contentShape(.rect(cornerRadius: 22, style: .continuous))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Episode: \(episode.name)")
    }
}

/// Two-row horizontal grid of episodes.
struct EpisodeGridShelf: View {
    let row: HomeRow
    let episodes: [Episode]
    let library: LibraryIdentifier

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HomeRowHeader(row: row, library: library)
            ScrollView(.horizontal) {
                LazyHGrid(rows: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 16) {
                    ForEach(episodes) { episode in
                        NavigationLink(value: NavigationDestination.item(episode.id)) {
                            CompactItemRow(item: AnyItem.episode(episode), coverSize: 60)
                        }
                        .buttonStyle(.plain)
                        .itemActions(for: .episode(episode), swipeActions: false)
                        .containerRelativeFrame(.horizontal) { length, _ in
                            sizeClass == .compact ? length - 64 : min(380, length / 2.4)
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
}

private struct HomeRowHeader: View {
    let row: HomeRow
    let library: LibraryIdentifier

    var body: some View {
        NavigationLink(value: NavigationDestination.homeRow(row, library: library)) {
            HStack(spacing: 4) {
                Text(HomeRowTitle.title(for: row))
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.title3.weight(.semibold))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .accessibilityAddTraits(.isHeader)
    }
}
