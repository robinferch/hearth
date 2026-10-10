import HearthData
import HearthModel
import HearthUI
import SwiftUI

/// Root content of a library tab (or the same screen pushed from a shortcut row).
struct LibraryTabScreen: View {
    let library: LibraryIdentifier
    let tab: LibraryTab
    /// Root of a tab (shows the library picker on iPhone) vs. pushed.
    let isRoot: Bool

    private var connections: ConnectionStore { HearthData.shared.connections }

    var body: some View {
        if let library = connections.library(library) {
            if isRoot {
                screen(for: library)
                    .libraryRootToolbar(showsListenNow: tab == .home)
            } else {
                screen(for: library)
            }
        } else if connections.status[library.connectionID] == .offline {
            ConnectionFailureView(connectionID: library.connectionID)
        } else {
            LoadingView()
        }
    }

    @ViewBuilder
    private func screen(for library: Library) -> some View {
        switch tab {
        case .home:
            switch library.mediaType {
            case .audiobooks: AudiobookHomeView(library: library)
            case .podcasts: PodcastHomeView(library: library)
            }
        case .library:
            switch library.mediaType {
            case .audiobooks: AudiobookLibraryView(library: library)
            case .podcasts: PodcastLibraryView(library: library)
            }
        case .latest:
            LatestEpisodesView(library: library)
        case .series:
            SeriesListView(library: library)
        case .authors:
            AuthorsListView(library: library)
        case .narrators:
            NarratorsListView(library: library)
        case .bookmarks:
            BookmarksView(library: library)
        case .collections:
            CollectionsListView(library: library, kind: .collection)
        case .playlists:
            CollectionsListView(library: library, kind: .playlist)
        case .downloaded:
            DownloadedView(library: library.id)
        case .statistics:
            StatisticsView(connectionID: library.connectionID)
        }
    }
}

/// Wraps a tab's root in a `NavigationStack` bound to the navigator's path for that tab.
struct TabRoot<Content: View>: View {
    let tab: TabValue
    let content: Content

    @Environment(Navigator.self) private var navigator

    init(tab: TabValue, @ViewBuilder content: () -> Content) {
        self.tab = tab
        self.content = content()
    }

    var body: some View {
        NavigationStack(path: navigator.path(for: tab)) {
            content
                .hearthNavigationDestinations()
        }
    }
}
