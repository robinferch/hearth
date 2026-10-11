import HearthData
import HearthModel
import HearthUI
import SwiftUI

/// All audiobooks of a library with shortcut rows, grid/list, filters, sort and series grouping.
struct AudiobookLibraryView: View {
    let library: Library
    /// Fixed server filter (genre / tag pages); hides the shortcut rows and filter menu.
    var fixedFilter: LibraryItemFilter?
    var title: String?

    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("library.shortcuts") private var shortcutsRaw = "series,authors,narrators,collections"

    @State private var loader = PagedLoader<LibraryEntry> { _, _ in Page(items: [], total: 0, page: 0) }
    @State private var sort = SortState<AudiobookSortOrder>(sort: .added, direction: .descending)
    @State private var displayMode: DisplayMode = .grid
    @State private var filter: LibraryItemFilter?
    @State private var downloadedOnly = false
    @State private var filterData: LibraryFilterData?
    @State private var isCustomizingShortcuts = false
    @State private var didLoadSettings = false

    private var settings: AppSettings { .shared }
    private var storageKey: String { "audiobooks-\(library.id.description)" }
    private var isFiltered: Bool { fixedFilter != nil }

    private var shortcuts: [LibraryTab] {
        shortcutsRaw.split(separator: ",").compactMap { LibraryTab(rawValue: String($0)) }.filter { LibraryTab.shortcutCandidates.contains($0) }
    }

    private struct QueryKey: Hashable {
        var library: LibraryIdentifier
        var sort: AudiobookSortOrder
        var direction: SortDirection
        var filter: LibraryItemFilter?
        var collapse: Bool
        var ready: Bool
    }

    private var queryKey: QueryKey {
        QueryKey(library: library.id, sort: sort.sort, direction: sort.direction, filter: fixedFilter ?? filter, collapse: settings.groupBooksInSeries && !isFiltered, ready: didLoadSettings)
    }

    var body: some View {
        content
            .navigationTitle(title ?? library.name)
            .toolbar { toolbar }
            .refreshable { await loader.reload() }
            .task {
                loadSettingsIfNeeded()
            }
            .task(id: queryKey) {
                guard didLoadSettings else { return }
                await reload()
            }
            .task(id: library.id) {
                filterData = try? await Client.for(library.connectionID).filterData(library: library.id)
            }
            .onChange(of: sort) { _, newValue in newValue.save(key: storageKey) }
            .onChange(of: displayMode) { _, newValue in HearthData.shared.itemSettings.setDisplayMode(newValue, for: storageKey) }
            .sheet(isPresented: $isCustomizingShortcuts) {
                ShortcutsEditor(raw: $shortcutsRaw)
            }
    }

    private func loadSettingsIfNeeded() {
        guard !didLoadSettings else { return }
        sort = .load(key: storageKey, default: .added, direction: .descending)
        displayMode = HearthData.shared.itemSettings.displayMode(for: storageKey)
        didLoadSettings = true
    }

    private func reload() async {
        let key = queryKey
        let libraryID = library.id
        let connectionID = library.connectionID
        await loader.load(key: key) { page, limit in
            try await Client.for(connectionID).audiobooks(library: libraryID, sort: key.sort, direction: key.direction, filter: key.filter, collapseSeries: key.collapse, page: page, limit: limit)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if downloadedOnly {
            downloadedContent
        } else {
            PagedContent(loader: loader, emptyTitle: String(localized: "No Audiobooks"), emptySymbol: "books.vertical") {
                switch displayMode {
                case .grid: gridContent
                case .list: listContent
                }
            }
        }
    }

    private var gridContent: some View {
        ScrollView {
            if !isFiltered, !shortcuts.isEmpty {
                ShortcutRows(library: library.id, tabs: shortcuts)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }
            LazyVGrid(columns: AdaptiveGrid.columns(compact: sizeClass == .compact), spacing: 22) {
                ForEach(loader.items) { entry in
                    entryCell(entry, grid: true)
                        .onAppear { Task { await loader.loadMore(ifNeededFor: entry) } }
                }
            }
            .padding(20)
            footer
        }
    }

    private var listContent: some View {
        List {
            if !isFiltered, !shortcuts.isEmpty {
                Section {
                    ForEach(shortcuts, id: \.self) { tab in
                        NavigationLink(value: NavigationDestination.libraryTab(tab, library: library.id)) {
                            Label(tab.title, systemImage: tab.systemImage)
                        }
                    }
                }
            }
            Section {
                ForEach(loader.items) { entry in
                    entryCell(entry, grid: false)
                        .onAppear { Task { await loader.loadMore(ifNeededFor: entry) } }
                }
            } footer: {
                footer
            }
        }
        .listStyle(.plain)
    }

    private var footer: some View {
        PagedFooter(loader: loader) { String(localized: "\($0) audiobooks") }
    }

    @ViewBuilder
    private func entryCell(_ entry: LibraryEntry, grid: Bool) -> some View {
        switch entry {
        case .audiobook(let book):
            bookCell(book, grid: grid)
        case .collapsedSeries(let series):
            if !settings.showSingleEntrySeries, series.bookCount == 1, let book = series.audiobooks.first {
                bookCell(book, grid: grid)
            } else {
                NavigationLink(value: NavigationDestination.item(series.id)) {
                    if grid {
                        SeriesGridCell(series: series)
                    } else {
                        SeriesRow(series: series)
                    }
                }
                .buttonStyle(.plain)
                .itemActions(for: .series(series))
            }
        }
    }

    @ViewBuilder
    private func bookCell(_ book: Audiobook, grid: Bool) -> some View {
        NavigationLink(value: NavigationDestination.item(book.id)) {
            if grid {
                AudiobookGridCell(audiobook: book)
            } else {
                AudiobookRow(audiobook: book)
            }
        }
        .buttonStyle(.plain)
        .itemActions(for: .audiobook(book), swipeActions: !grid)
        .draggable(book.id.description)
    }

    // MARK: Downloaded

    @ViewBuilder
    private var downloadedContent: some View {
        let books = sortedDownloads
        if books.isEmpty {
            EmptyStateView(title: String(localized: "No Downloads"), systemImage: "arrow.down.circle", message: String(localized: "Downloaded audiobooks of this library appear here."))
        } else {
            switch displayMode {
            case .grid:
                ScrollView {
                    LazyVGrid(columns: AdaptiveGrid.columns(compact: sizeClass == .compact), spacing: 22) {
                        ForEach(books) { bookCell($0, grid: true) }
                    }
                    .padding(20)
                    CountFooter(text: String(localized: "\(books.count) audiobooks"))
                }
            case .list:
                List {
                    Section {
                        ForEach(books) { bookCell($0, grid: false) }
                    } footer: {
                        CountFooter(text: String(localized: "\(books.count) audiobooks"))
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private var sortedDownloads: [Audiobook] {
        let books = HearthData.shared.downloads.downloadedAudiobooks(in: library.id)
        let sorted: [Audiobook] = switch sort.sort {
        case .title: books.sorted { $0.sortName < $1.sortName }
        case .author, .authorLastFirst: books.sorted { ($0.authorLine ?? "") < ($1.authorLine ?? "") }
        case .published: books.sorted { ($0.released ?? "") < ($1.released ?? "") }
        case .added, .lastUpdated: books.sorted { ($0.addedAt ?? .distantPast) < ($1.addedAt ?? .distantPast) }
        case .duration: books.sorted { $0.duration < $1.duration }
        case .size: books.sorted { ($0.size ?? 0) < ($1.size ?? 0) }
        }
        return sort.direction.isDescending ? sorted.reversed() : sorted
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if !isFiltered, let filterData, !(filterData.genres.isEmpty && filterData.tags.isEmpty) {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        filter = nil
                    } label: {
                        Label("All Audiobooks", systemImage: filter == nil ? "checkmark" : "books.vertical")
                    }
                    if !filterData.genres.isEmpty {
                        Menu("Genres") {
                            ForEach(filterData.genres, id: \.self) { genre in
                                Button {
                                    filter = .genre(genre)
                                } label: {
                                    if filter == .genre(genre) {
                                        Label(genre, systemImage: "checkmark")
                                    } else {
                                        Text(genre)
                                    }
                                }
                            }
                        }
                    }
                    if !filterData.tags.isEmpty {
                        Menu("Tags") {
                            ForEach(filterData.tags, id: \.self) { tag in
                                Button {
                                    filter = .tag(tag)
                                } label: {
                                    if filter == .tag(tag) {
                                        Label(tag, systemImage: "checkmark")
                                    } else {
                                        Text(tag)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Label("Filter", systemImage: "tag")
                }
                .symbolVariant(isGenreOrTagFilter ? .fill : .none)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                DisplayModeSection(mode: $displayMode)
                if !isFiltered {
                    Section("Show") {
                        ForEach([ProgressFilter.all, .inProgress, .finished, .notFinished, .notStarted], id: \.self) { option in
                            Button {
                                filter = option == .all ? nil : .progress(option)
                            } label: {
                                if progressFilter == option {
                                    Label(option.title, systemImage: "checkmark")
                                } else {
                                    Text(option.title)
                                }
                            }
                        }
                        Toggle(isOn: $downloadedOnly) {
                            Label("Downloaded", systemImage: "arrow.down.circle")
                        }
                    }
                }
                SortMenuSection(options: AudiobookSortOrder.menuOptions, state: $sort)
                if !isFiltered {
                    Section {
                        Toggle(isOn: Bindable(settings).groupBooksInSeries) {
                            Label("Group Books in Series", systemImage: "rectangle.stack")
                        }
                        Button {
                            isCustomizingShortcuts = true
                        } label: {
                            Label("Customize", systemImage: "slider.horizontal.3")
                        }
                    }
                }
            } label: {
                Label("Options", systemImage: "ellipsis")
            }
        }
    }

    private var progressFilter: ProgressFilter {
        if case .progress(let value) = filter { value } else if filter == nil { .all } else { .all }
    }

    private var isGenreOrTagFilter: Bool {
        switch filter {
        case .genre, .tag: true
        default: false
        }
    }
}

/// Audiobooks filtered by genre / tag / … (pushed from detail pages).
struct FilteredAudiobooksView: View {
    let library: LibraryIdentifier
    let filter: LibraryItemFilter
    let title: String

    var body: some View {
        if let library = HearthData.shared.connections.library(library) {
            AudiobookLibraryView(library: library, fixedFilter: filter, title: title)
        } else {
            LoadingView()
        }
    }
}

/// Shortcut rows (Series, Authors, …) shown above the library grid.
struct ShortcutRows: View {
    let library: LibraryIdentifier
    let tabs: [LibraryTab]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element) { index, tab in
                NavigationLink(value: NavigationDestination.libraryTab(tab, library: library)) {
                    HStack {
                        Label(tab.title, systemImage: tab.systemImage)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                #if os(iOS)
                .hoverEffect(.highlight)
                #endif
                if index < tabs.count - 1 {
                    Divider().padding(.leading, 52)
                }
            }
        }
        .background(.background.secondary, in: .rect(cornerRadius: 16, style: .continuous))
    }
}

/// Toggles which shortcut rows appear at the top of the library.
struct ShortcutsEditor: View {
    @Binding var raw: String

    @Environment(\.dismiss) private var dismiss

    private var selected: [LibraryTab] {
        raw.split(separator: ",").compactMap { LibraryTab(rawValue: String($0)) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(LibraryTab.shortcutCandidates, id: \.self) { tab in
                        Toggle(isOn: Binding(
                            get: { selected.contains(tab) },
                            set: { isOn in
                                var tabs = selected.filter { $0 != tab }
                                if isOn { tabs.append(tab) }
                                raw = LibraryTab.shortcutCandidates.filter { tabs.contains($0) }.map(\.rawValue).joined(separator: ",")
                            }
                        )) {
                            Label(tab.title, systemImage: tab.systemImage)
                        }
                    }
                } footer: {
                    Text("Shortcuts appear above your audiobooks.")
                }
            }
            .navigationTitle("Shortcuts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
