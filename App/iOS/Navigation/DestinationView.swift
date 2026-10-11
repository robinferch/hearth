import HearthData
import HearthModel
import HearthUI
import SwiftUI

extension View {
    /// Registers the app's `NavigationDestination` mapping. Apply inside every `NavigationStack`.
    func hearthNavigationDestinations() -> some View {
        navigationDestination(for: NavigationDestination.self) { destination in
            DestinationView(destination: destination)
        }
    }
}

/// Maps a `NavigationDestination` to its screen.
struct DestinationView: View {
    let destination: NavigationDestination

    var body: some View {
        switch destination {
        case .item(let id):
            ItemDestinationView(id: id)
        case .author(let name, let library):
            NamedItemResolver(kind: .author, name: name, library: library)
        case .narrator(let name, let library):
            // Narrators are identified by name on audiobookshelf.
            PersonDetailView(id: ItemIdentifier(kind: .narrator, connectionID: library.connectionID, libraryID: library.libraryID, primaryID: name))
        case .series(let name, let library):
            NamedItemResolver(kind: .series, name: name, library: library)
        case .homeRow(let row, let library):
            HomeRowGridView(row: row, library: library)
        case .allEpisodes(let podcast):
            AllEpisodesView(podcastID: podcast)
        case .libraryTab(let tab, let library):
            LibraryTabScreen(library: library, tab: tab, isRoot: false)
        case .filteredAudiobooks(let filter, let title, let library):
            FilteredAudiobooksView(library: library, filter: filter, title: title)
        }
    }
}

/// Detail screen for any item kind.
struct ItemDestinationView: View {
    let id: ItemIdentifier

    var body: some View {
        switch id.kind {
        case .audiobook: AudiobookDetailView(id: id)
        case .podcast: PodcastDetailView(id: id)
        case .episode: EpisodeDetailView(id: id)
        case .series: SeriesDetailView(id: id)
        case .author, .narrator: PersonDetailView(id: id)
        case .collection, .playlist: CollectionDetailView(id: id)
        }
    }
}

/// Resolves an author / series by name through search, then shows its detail page.
struct NamedItemResolver: View {
    let kind: ItemIdentifier.Kind
    let name: String
    let library: LibraryIdentifier

    @State private var state: LoadState<ItemIdentifier?> = .loading

    var body: some View {
        LoadStateView(state, retry: resolve) { id in
            if let id {
                ItemDestinationView(id: id)
            } else {
                EmptyStateView(title: String(localized: "Not Found"), systemImage: "magnifyingglass", message: name)
            }
        }
        .task { await resolve() }
    }

    private func resolve() async {
        let results = await HearthData.shared.items.search(name, scope: .library(library))
        let candidates: [any Item] = kind == .series ? results.series : results.authors
        // Exact name only: search is fuzzy, and another author / series must not stand in ("Not Found" instead).
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let match = candidates.first {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).compare(wanted, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame
        }
        state = .loaded(match?.id)
    }
}

// MARK: - Handoff

extension View {
    /// Advertises the item for Handoff / Siri suggestions (`<bundle>.item`, webpage = ABS web URL).
    func itemUserActivity(_ id: ItemIdentifier, title: String? = nil) -> some View {
        modifier(ItemUserActivityModifier(id: id, title: title))
    }
}

private struct ItemUserActivityModifier: ViewModifier {
    let id: ItemIdentifier
    let title: String?

    func body(content: Content) -> some View {
        let webURL = (try? HearthData.shared.connections.client(for: id.connectionID))?.webURL(for: id)
        let id = id
        let title = title
        content.userActivity(UserActivity.itemType) { activity in
            activity.title = title
            activity.userInfo = [UserActivity.itemIDKey: id.description]
            activity.targetContentIdentifier = id.description
            activity.isEligibleForHandoff = true
            activity.isEligibleForPrediction = true
            activity.webpageURL = webURL
        }
    }
}
