import HearthData
import HearthModel
import HearthUI
import SwiftUI

// MARK: - Podcasts

/// Podcasts of a library: grid (min 160 / 200) with unplayed badge, or list.
struct PodcastLibraryView: View {
    let library: Library

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var loader = PagedLoader<Podcast> { _, _ in Page(items: [], total: 0, page: 0) }
    @State private var sort = SortState<PodcastSortOrder>(sort: .title, direction: .ascending)
    @State private var displayMode: DisplayMode = .grid
    @State private var ready = false

    private var key: String { "podcasts-\(library.id.description)" }

    var body: some View {
        PagedContent(loader: loader, emptyTitle: String(localized: "No Podcasts"), emptySymbol: "antenna.radiowaves.left.and.right") {
            switch displayMode {
            case .grid:
                ScrollView {
                    LazyVGrid(columns: AdaptiveGrid.columns(compact: sizeClass == .compact, minimumCompact: 160, minimumRegular: 200), spacing: 22) {
                        ForEach(loader.items) { podcast in
                            NavigationLink(value: NavigationDestination.item(podcast.id)) {
                                PodcastGridCell(podcast: podcast)
                            }
                            .buttonStyle(.plain)
                            .itemActions(for: .podcast(podcast))
                            .onAppear { Task { await loader.loadMore(ifNeededFor: podcast) } }
                        }
                    }
                    .padding(20)
                    footer
                }
            case .list:
                List {
                    Section {
                        ForEach(loader.items) { podcast in
                            NavigationLink(value: NavigationDestination.item(podcast.id)) {
                                CompactItemRow(item: AnyItem.podcast(podcast), coverSize: 64)
                            }
                            .itemActions(for: .podcast(podcast))
                            .onAppear { Task { await loader.loadMore(ifNeededFor: podcast) } }
                        }
                    } footer: {
                        footer
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(library.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    DisplayModeSection(mode: $displayMode)
                    SortMenuSection(options: Array(PodcastSortOrder.allCases), state: $sort)
                } label: {
                    Label("Options", systemImage: "ellipsis")
                }
            }
        }
        .refreshable { await loader.reload() }
        .task {
            guard !ready else { return }
            sort = .load(key: key, default: .title)
            displayMode = HearthData.shared.itemSettings.displayMode(for: key)
            ready = true
        }
        .task(id: ready ? sort : nil) {
            guard ready else { return }
            sort.save(key: key)
            let state = sort
            let libraryID = library.id
            await loader.reset { page, limit in
                try await Client.for(libraryID.connectionID).podcasts(library: libraryID, sort: state.sort, direction: state.direction, page: page, limit: limit)
            }
        }
        .onChange(of: displayMode) { _, mode in HearthData.shared.itemSettings.setDisplayMode(mode, for: key) }
    }

    @ViewBuilder
    private var footer: some View {
        if loader.isLoading {
            PageLoadingIndicator()
        } else if let total = loader.total {
            CountFooter(text: String(localized: "\(total) podcasts"))
        }
    }
}

// MARK: - Series

/// Series grid (collage) or list (fanned covers).
struct SeriesListView: View {
    let library: Library

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var loader = PagedLoader<Series> { _, _ in Page(items: [], total: 0, page: 0) }
    @State private var sort = SortState<SeriesSortOrder>(sort: .name, direction: .ascending)
    @State private var displayMode: DisplayMode = .grid
    @State private var ready = false

    private var key: String { "series-\(library.id.description)" }

    var body: some View {
        PagedContent(loader: loader, emptyTitle: String(localized: "No Series"), emptySymbol: "rectangle.stack") {
            switch displayMode {
            case .grid:
                ScrollView {
                    LazyVGrid(columns: AdaptiveGrid.columns(compact: sizeClass == .compact), spacing: 22) {
                        ForEach(loader.items) { series in
                            NavigationLink(value: NavigationDestination.item(series.id)) {
                                SeriesGridCell(series: series)
                            }
                            .buttonStyle(.plain)
                            .itemActions(for: .series(series))
                            .onAppear { Task { await loader.loadMore(ifNeededFor: series) } }
                        }
                    }
                    .padding(20)
                    footer
                }
            case .list:
                List {
                    Section {
                        ForEach(loader.items) { series in
                            NavigationLink(value: NavigationDestination.item(series.id)) {
                                SeriesRow(series: series)
                            }
                            .itemActions(for: .series(series))
                            .onAppear { Task { await loader.loadMore(ifNeededFor: series) } }
                        }
                    } footer: {
                        footer
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Series")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    DisplayModeSection(mode: $displayMode)
                    SortMenuSection(options: Array(SeriesSortOrder.allCases), state: $sort)
                } label: {
                    Label("Options", systemImage: "ellipsis")
                }
            }
        }
        .refreshable { await loader.reload() }
        .task {
            guard !ready else { return }
            sort = .load(key: key, default: .name)
            displayMode = HearthData.shared.itemSettings.displayMode(for: key)
            ready = true
        }
        .task(id: ready ? sort : nil) {
            guard ready else { return }
            sort.save(key: key)
            let state = sort
            let libraryID = library.id
            await loader.reset { page, limit in
                try await Client.for(libraryID.connectionID).series(library: libraryID, sort: state.sort, direction: state.direction, filter: nil, page: page, limit: limit)
            }
        }
        .onChange(of: displayMode) { _, mode in HearthData.shared.itemSettings.setDisplayMode(mode, for: key) }
    }

    @ViewBuilder
    private var footer: some View {
        if loader.isLoading {
            PageLoadingIndicator()
        } else if let total = loader.total {
            CountFooter(text: String(localized: "\(total) series"))
        }
    }
}

// MARK: - Authors

struct AuthorsListView: View {
    let library: Library

    @State private var loader = PagedLoader<Person> { _, _ in Page(items: [], total: 0, page: 0) }
    @State private var sort = SortState<AuthorSortOrder>(sort: .firstLast, direction: .ascending)
    @State private var ready = false

    private var key: String { "authors-\(library.id.description)" }

    var body: some View {
        PagedContent(loader: loader, emptyTitle: String(localized: "No Authors"), emptySymbol: "person.2") {
            List {
                Section {
                    ForEach(loader.items) { author in
                        NavigationLink(value: NavigationDestination.item(author.id)) {
                            PersonRow(person: author)
                        }
                        .itemActions(for: .person(author))
                        .onAppear { Task { await loader.loadMore(ifNeededFor: author) } }
                    }
                } footer: {
                    if loader.isLoading {
                        PageLoadingIndicator()
                    } else if let total = loader.total {
                        CountFooter(text: String(localized: "\(total) authors"))
                    }
                }
            }
            .listStyle(.plain)
        }
        .navigationTitle("Authors")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    SortMenuSection(options: Array(AuthorSortOrder.allCases), state: $sort)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
        }
        .refreshable { await loader.reload() }
        .task {
            guard !ready else { return }
            sort = .load(key: key, default: .firstLast)
            ready = true
        }
        .task(id: ready ? sort : nil) {
            guard ready else { return }
            sort.save(key: key)
            let state = sort
            let libraryID = library.id
            await loader.reset { page, limit in
                try await Client.for(libraryID.connectionID).authors(library: libraryID, sort: state.sort, direction: state.direction, page: page, limit: limit)
            }
        }
    }
}

// MARK: - Narrators

struct NarratorsListView: View {
    let library: Library

    @State private var state: LoadState<[Person]> = .loading
    @State private var sort = SortState<NarratorSortOrder>(sort: .name, direction: .ascending)

    private var key: String { "narrators-\(library.id.description)" }

    var body: some View {
        LoadStateView(state, retry: load) { narrators in
            if narrators.isEmpty {
                EmptyStateView(title: String(localized: "No Narrators"), systemImage: "waveform")
            } else {
                List {
                    Section {
                        ForEach(sorted(narrators)) { narrator in
                            NavigationLink(value: NavigationDestination.item(narrator.id)) {
                                PersonRow(person: narrator)
                            }
                        }
                    } footer: {
                        CountFooter(text: String(localized: "\(narrators.count) narrators"))
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Narrators")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    SortMenuSection(options: Array(NarratorSortOrder.allCases), state: $sort)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
        }
        .refreshable { await load() }
        .task {
            sort = .load(key: key, default: .name)
            await load()
        }
        .onChange(of: sort) { _, value in value.save(key: key) }
    }

    private func sorted(_ narrators: [Person]) -> [Person] {
        let result: [Person] = switch sort.sort {
        case .name: narrators.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .bookCount: narrators.sorted { $0.bookCount < $1.bookCount }
        }
        return sort.direction.isDescending ? result.reversed() : result
    }

    private func load() async {
        do {
            state = .loaded(try await Client.for(library.connectionID).narrators(library: library.id))
        } catch {
            if state.value == nil {
                state = .failed(error)
            }
        }
    }
}

// MARK: - Bookmarks

/// Audiobooks that have bookmarks, with the bookmark count.
struct BookmarksView: View {
    let library: Library

    @State private var items: [ItemIdentifier: AnyItem] = [:]

    var body: some View {
        let entries = HearthData.shared.bookmarks.bookmarkedItems(in: library.id)
        Group {
            if entries.isEmpty {
                EmptyStateView(title: String(localized: "No Bookmarks"), systemImage: "bookmark", message: String(localized: "Bookmarks you create while listening appear here."))
            } else {
                List(entries, id: \.itemID) { entry in
                    NavigationLink(value: NavigationDestination.item(entry.itemID)) {
                        HStack {
                            if let item = items[entry.itemID] {
                                CompactItemRow(item: item, showsStatus: false)
                            } else {
                                ItemImage(id: entry.itemID, size: .tiny, cornerRadius: 6)
                                    .frame(width: 56, height: 56)
                                ProgressView()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Label("\(entry.count)", systemImage: "bookmark.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tint)
                                .accessibilityLabel("\(entry.count) bookmarks")
                        }
                    }
                    .task {
                        guard items[entry.itemID] == nil else { return }
                        if let item = try? await HearthData.shared.items.item(entry.itemID) {
                            items[entry.itemID] = item
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Bookmarks")
        .refreshable { await HearthData.shared.bookmarks.sync() }
    }
}

// MARK: - Collections & playlists

struct CollectionsListView: View {
    enum Kind {
        case collection
        case playlist
    }

    let library: Library
    let kind: Kind

    @State private var loader = PagedLoader<ItemCollection> { _, _ in Page(items: [], total: 0, page: 0) }

    var body: some View {
        PagedContent(loader: loader, emptyTitle: kind == .collection ? String(localized: "No Collections") : String(localized: "No Playlists"), emptySymbol: kind == .collection ? "square.stack" : "music.note.list") {
            List {
                Section {
                    ForEach(loader.items) { collection in
                        NavigationLink(value: NavigationDestination.item(collection.id)) {
                            CollectionRow(collection: collection)
                        }
                        .itemActions(for: .collection(collection))
                        .onAppear { Task { await loader.loadMore(ifNeededFor: collection) } }
                    }
                } footer: {
                    if loader.isLoading {
                        PageLoadingIndicator()
                    }
                }
            }
            .listStyle(.plain)
        }
        .navigationTitle(kind == .collection ? String(localized: "Collections") : String(localized: "Playlists"))
        .refreshable { await loader.reload() }
        .task(id: library.id) {
            let libraryID = library.id
            let kind = kind
            await loader.reset { page, limit in
                let client = try Client.for(libraryID.connectionID)
                return switch kind {
                case .collection: try await client.collections(library: libraryID, page: page, limit: limit)
                case .playlist: try await client.playlists(library: libraryID, page: page, limit: limit)
                }
            }
        }
    }
}

// MARK: - Downloaded

/// Downloaded episodes, then audiobooks.
struct DownloadedView: View {
    let library: LibraryIdentifier?

    var body: some View {
        let downloads = HearthData.shared.downloads
        let books = downloads.downloadedAudiobooks(in: library)
        let podcasts = downloads.downloadedPodcasts(in: library)
        let episodes = podcasts.flatMap { downloads.downloadedEpisodes(podcast: $0.id) }
        Group {
            if books.isEmpty, episodes.isEmpty {
                EmptyStateView(title: String(localized: "No Downloads"), systemImage: "arrow.down.circle", message: String(localized: "Download audiobooks and episodes to listen offline."))
            } else {
                List {
                    if !episodes.isEmpty {
                        Section("Episodes") {
                            ForEach(episodes) { episode in
                                NavigationLink(value: NavigationDestination.item(episode.id)) {
                                    CompactItemRow(item: AnyItem.episode(episode))
                                }
                                .itemActions(for: .episode(episode))
                            }
                        }
                    }
                    if !books.isEmpty {
                        Section("Audiobooks") {
                            ForEach(books) { book in
                                NavigationLink(value: NavigationDestination.item(book.id)) {
                                    AudiobookRow(audiobook: book)
                                }
                                .itemActions(for: .audiobook(book))
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Downloaded")
    }
}

// MARK: - Latest episodes

/// 20 most recent episodes of a podcast library.
struct LatestEpisodesView: View {
    let library: Library

    @State private var state: LoadState<[Episode]> = .loading

    var body: some View {
        LoadStateView(state, retry: load) { episodes in
            if episodes.isEmpty {
                EmptyStateView(title: String(localized: "No Episodes"), systemImage: "clock")
            } else {
                List(episodes) { episode in
                    NavigationLink(value: NavigationDestination.item(episode.id)) {
                        EpisodeRow(episode: episode)
                    }
                    .itemActions(for: .episode(episode))
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Latest")
        .refreshable { await load() }
        .task(id: library.id) { await load() }
    }

    private func load() async {
        do {
            state = .loaded(try await Client.for(library.connectionID).recentEpisodes(library: library.id, limit: 20))
        } catch {
            if state.value == nil {
                state = .failed(error)
            }
        }
    }
}
