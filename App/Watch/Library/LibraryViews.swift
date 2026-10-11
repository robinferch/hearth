import HearthAPI
import HearthData
import HearthModel
import HearthUI
import SwiftUI

/// Sections of one library.
struct LibraryView: View {
    let libraryID: LibraryIdentifier

    private var library: Library? { HearthData.shared.connections.library(libraryID) }

    var body: some View {
        List {
            if library?.mediaType == .podcasts {
                NavigationLink(value: WatchRoute.podcasts(libraryID)) {
                    Label("Podcasts", systemImage: "antenna.radiowaves.left.and.right")
                }
            } else {
                NavigationLink(value: WatchRoute.audiobooks(libraryID)) {
                    Label("Audiobooks", systemImage: "book.closed")
                }
                NavigationLink(value: WatchRoute.series(libraryID)) {
                    Label("Series", systemImage: "books.vertical")
                }
                NavigationLink(value: WatchRoute.authors(libraryID)) {
                    Label("Authors", systemImage: "person.2")
                }
            }
        }
        .navigationTitle(library?.name ?? String(localized: "Library"))
    }
}

// MARK: - Lists

struct AudiobooksView: View {
    let libraryID: LibraryIdentifier
    @State private var loader: WatchPagedLoader<LibraryEntry>

    init(libraryID: LibraryIdentifier) {
        self.libraryID = libraryID
        _loader = State(initialValue: WatchPagedLoader { page, limit in
            try await WatchClient.for(libraryID.connectionID).audiobooks(library: libraryID, sort: .title, direction: .ascending, filter: nil, collapseSeries: false, page: page, limit: limit)
        })
    }

    var body: some View {
        PagedList(loader: loader, emptyTitle: "No Audiobooks") { entry in
            switch entry {
            case .audiobook(let audiobook):
                NavigationLink(value: WatchRoute.item(audiobook.id)) {
                    WatchItemRow(audiobook: audiobook)
                }
            case .collapsedSeries(let series):
                NavigationLink(value: WatchRoute.item(series.id)) {
                    WatchGroupRow(id: series.id, coverID: series.audiobooks.first?.id, title: series.name, subtitle: HearthFormat.bookCount(series.bookCount))
                }
            }
        }
        .navigationTitle("Audiobooks")
    }
}

struct SeriesListView: View {
    let libraryID: LibraryIdentifier
    @State private var loader: WatchPagedLoader<Series>

    init(libraryID: LibraryIdentifier) {
        self.libraryID = libraryID
        _loader = State(initialValue: WatchPagedLoader { page, limit in
            try await WatchClient.for(libraryID.connectionID).series(library: libraryID, sort: .name, direction: .ascending, filter: nil, page: page, limit: limit)
        })
    }

    var body: some View {
        PagedList(loader: loader, emptyTitle: "No Series") { series in
            NavigationLink(value: WatchRoute.item(series.id)) {
                WatchGroupRow(id: series.id, coverID: series.audiobooks.first?.id, title: series.name, subtitle: HearthFormat.bookCount(series.bookCount))
            }
        }
        .navigationTitle("Series")
    }
}

struct AuthorsView: View {
    let libraryID: LibraryIdentifier
    @State private var loader: WatchPagedLoader<Person>

    init(libraryID: LibraryIdentifier) {
        self.libraryID = libraryID
        _loader = State(initialValue: WatchPagedLoader { page, limit in
            try await WatchClient.for(libraryID.connectionID).authors(library: libraryID, sort: .firstLast, direction: .ascending, page: page, limit: limit)
        })
    }

    var body: some View {
        PagedList(loader: loader, emptyTitle: "No Authors") { author in
            NavigationLink(value: WatchRoute.item(author.id)) {
                WatchGroupRow(id: author.id, coverID: author.hasImage ? author.id : nil, title: author.name, subtitle: HearthFormat.bookCount(author.bookCount))
            }
        }
        .navigationTitle("Authors")
    }
}

struct PodcastsView: View {
    let libraryID: LibraryIdentifier
    @State private var loader: WatchPagedLoader<Podcast>

    init(libraryID: LibraryIdentifier) {
        self.libraryID = libraryID
        _loader = State(initialValue: WatchPagedLoader { page, limit in
            try await WatchClient.for(libraryID.connectionID).podcasts(library: libraryID, sort: .title, direction: .ascending, page: page, limit: limit)
        })
    }

    var body: some View {
        PagedList(loader: loader, emptyTitle: "No Podcasts") { podcast in
            NavigationLink(value: WatchRoute.item(podcast.id)) {
                WatchGroupRow(id: podcast.id, coverID: podcast.id, title: podcast.name, subtitle: HearthFormat.episodeCount(podcast.episodeCount))
            }
        }
        .navigationTitle("Podcasts")
    }
}

// MARK: - Grouping details

/// Loads a value once and shows loading / error states.
struct AsyncContent<Value, Content: View>: View {
    let load: @MainActor () async throws -> Value
    @ViewBuilder let content: (Value) -> Content

    @State private var value: Value?
    @State private var error: (any Error)?

    var body: some View {
        Group {
            if let value {
                content(value)
            } else if let error {
                WatchErrorView(error: error) { await reload() }
            } else {
                ProgressView()
            }
        }
        .task {
            guard value == nil else { return }
            await reload()
        }
    }

    private func reload() async {
        error = nil
        do {
            value = try await load()
        } catch {
            if !(error is CancellationError) {
                self.error = error
            }
        }
    }
}

struct SeriesDetailView: View {
    let id: ItemIdentifier

    var body: some View {
        AsyncContent {
            try await WatchClient.for(id.connectionID).seriesDetails(id)
        } content: { series in
            List {
                if let next = series.audiobooks.first(where: { !ItemStatus.of($0.id).isFinished }) {
                    Button {
                        Task { await WatchPlayer.shared.playLocally(next.id, origin: .series(id)) }
                    } label: {
                        Label("Play \(HearthFormat.sequence(next.series.first { $0.id == id.primaryID }?.sequence) ?? next.name)", systemImage: "play.fill")
                            .lineLimit(2)
                    }
                    .listItemTint(.accentColor)
                }
                ForEach(series.audiobooks) { audiobook in
                    NavigationLink(value: WatchRoute.item(audiobook.id)) {
                        WatchItemRow(id: audiobook.id, title: audiobook.name, subtitle: HearthFormat.sequence(audiobook.series.first { $0.id == id.primaryID }?.sequence) ?? audiobook.authorLine)
                    }
                }
            }
            .navigationTitle(series.name)
        }
    }
}

struct AuthorDetailView: View {
    let id: ItemIdentifier

    var body: some View {
        AsyncContent {
            try await WatchClient.for(id.connectionID).author(id)
        } content: { result in
            List {
                Section {
                    HStack {
                        ItemImage(id: id, size: .tiny)
                            .frame(width: 44, height: 44)
                        Text(result.author.name)
                            .font(.headline)
                    }
                    .listRowBackground(Color.clear)
                }
                if !result.series.isEmpty {
                    Section("Series") {
                        ForEach(result.series) { series in
                            NavigationLink(value: WatchRoute.item(series.id)) {
                                WatchGroupRow(id: series.id, coverID: series.audiobooks.first?.id, title: series.name, subtitle: HearthFormat.bookCount(max(series.bookCount, series.audiobooks.count)))
                            }
                        }
                    }
                }
                Section("Audiobooks") {
                    ForEach(result.audiobooks) { audiobook in
                        NavigationLink(value: WatchRoute.item(audiobook.id)) {
                            WatchItemRow(audiobook: audiobook)
                        }
                    }
                }
            }
            .navigationTitle(result.author.name)
        }
    }
}

struct PodcastDetailView: View {
    let id: ItemIdentifier

    var body: some View {
        AsyncContent {
            try await HearthData.shared.items.podcast(id)
        } content: { result in
            let episodes = result.episodes.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
            List {
                Section {
                    HStack(spacing: 8) {
                        ItemImage(id: id, size: .tiny, cornerRadius: 6)
                            .frame(width: 48, height: 48)
                        VStack(alignment: .leading) {
                            Text(result.podcast.name)
                                .font(.headline)
                                .lineLimit(3)
                            if let author = result.podcast.authorLine {
                                Text(author)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                Section("Episodes") {
                    ForEach(episodes) { episode in
                        NavigationLink(value: WatchRoute.item(episode.id)) {
                            WatchItemRow(item: .episode(episode))
                        }
                    }
                }
            }
            .navigationTitle(result.podcast.name)
        }
    }
}
