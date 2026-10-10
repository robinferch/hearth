import HearthData
import HearthModel
import HearthUI
import SwiftUI

enum SearchScopeOption: Hashable {
    case library
    case everywhere
}

/// Search tab: scopes "This library" / "Everywhere", 0.3 s debounce, sectioned results, recent searches.
struct SearchView: View {
    @Environment(Navigator.self) private var navigator
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("search.recent") private var recentRaw = ""

    @State private var scope: SearchScopeOption = .library
    @State private var results: SearchResults?
    @State private var isSearching = false

    private var connections: ConnectionStore { HearthData.shared.connections }

    private var recentSearches: [String] {
        recentRaw.split(separator: "\n").map(String.init)
    }

    private struct QueryKey: Hashable {
        var text: String
        var scope: SearchScopeOption
        var library: LibraryIdentifier?
    }

    var body: some View {
        @Bindable var navigator = navigator
        let library = navigator.resolvedLibrary(connections: connections)

        content
            .navigationTitle("Search")
            .searchable(text: $navigator.searchText, isPresented: $navigator.isSearchPresented, prompt: Text(scope == .library ? "Search \(library?.name ?? String(localized: "Library"))" : String(localized: "Search Everywhere")))
            .searchScopes($scope, activation: .onSearchPresentation) {
                Text("This Library").tag(SearchScopeOption.library)
                Text("Everywhere").tag(SearchScopeOption.everywhere)
            }
            .searchSuggestions {
                if navigator.searchText.isEmpty {
                    ForEach(recentSearches, id: \.self) { query in
                        Label(query, systemImage: "clock.arrow.circlepath")
                            .searchCompletion(query)
                    }
                }
            }
            .onSubmit(of: .search) {
                remember(navigator.searchText)
            }
            .task(id: QueryKey(text: navigator.searchText, scope: scope, library: library?.id)) {
                await search(navigator.searchText, library: library?.id)
            }
            .toolbar {
                if sizeClass == .compact {
                    ToolbarItem(placement: .topBarLeading) {
                        LibraryPickerMenu()
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if navigator.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            if recentSearches.isEmpty {
                ContentUnavailableView("Search Your Libraries", systemImage: "magnifyingglass", description: Text("Find audiobooks, podcasts, episodes, series, authors and narrators."))
            } else {
                List {
                    Section {
                        ForEach(recentSearches, id: \.self) { query in
                            Button {
                                navigator.searchText = query
                            } label: {
                                Label(query, systemImage: "clock.arrow.circlepath")
                            }
                            .foregroundStyle(.primary)
                        }
                    } header: {
                        HStack {
                            Text("Recent Searches")
                            Spacer()
                            Button("Clear") { recentRaw = "" }
                                .font(.subheadline)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        } else if let results {
            if results.isEmpty {
                ContentUnavailableView.search(text: navigator.searchText)
            } else {
                resultsList(results)
            }
        } else {
            LoadingView(String(localized: "Searching…"), systemImage: "magnifyingglass")
        }
    }

    private func resultsList(_ results: SearchResults) -> some View {
        List {
            if !results.audiobooks.isEmpty {
                Section("Audiobooks") {
                    ForEach(results.audiobooks) { book in
                        link(.item(book.id)) { CompactItemRow(item: AnyItem.audiobook(book)) }
                            .itemActions(for: .audiobook(book))
                    }
                }
            }
            if !results.podcasts.isEmpty {
                Section("Podcasts") {
                    ForEach(results.podcasts) { podcast in
                        link(.item(podcast.id)) { CompactItemRow(item: AnyItem.podcast(podcast)) }
                            .itemActions(for: .podcast(podcast))
                    }
                }
            }
            if !results.episodes.isEmpty {
                Section("Episodes") {
                    ForEach(results.episodes) { episode in
                        link(.item(episode.id)) { CompactItemRow(item: AnyItem.episode(episode)) }
                            .itemActions(for: .episode(episode))
                    }
                }
            }
            if !results.series.isEmpty {
                Section("Series") {
                    ForEach(results.series) { series in
                        link(.item(series.id)) { SeriesRow(series: series) }
                            .itemActions(for: .series(series))
                    }
                }
            }
            if !results.authors.isEmpty {
                Section("Authors") {
                    ForEach(results.authors) { author in
                        link(.item(author.id)) { PersonRow(person: author, avatarSize: 44) }
                    }
                }
            }
            if !results.narrators.isEmpty {
                Section("Narrators") {
                    ForEach(results.narrators) { narrator in
                        link(.item(narrator.id)) { PersonRow(person: narrator, avatarSize: 44) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.immediately)
    }

    private func link<Label: View>(_ destination: NavigationDestination, @ViewBuilder label: () -> Label) -> some View {
        NavigationLink(value: destination) {
            label()
        }
        .simultaneousGesture(TapGesture().onEnded { remember(navigator.searchText) })
    }

    private func search(_ text: String, library: LibraryIdentifier?) async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            results = nil
            return
        }
        // 0.3 s debounce: the task is cancelled when the text changes.
        do {
            try await Task.sleep(for: .milliseconds(300))
        } catch {
            return
        }
        let searchScope: SearchScope = if scope == .library, let library { .library(library) } else { .everywhere }
        isSearching = true
        let found = await HearthData.shared.items.search(query, scope: searchScope)
        guard !Task.isCancelled else { return }
        results = found
        isSearching = false
    }

    private func remember(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var recent = recentSearches.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        recent.insert(trimmed, at: 0)
        recentRaw = recent.prefix(8).joined(separator: "\n")
    }
}
