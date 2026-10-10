import HearthData
import HearthModel
import HearthUI
import SwiftUI

/// Sort option with a localized title and symbol.
protocol LibrarySortOption: RawRepresentable, Hashable, Sendable, CaseIterable where RawValue == String {
    var title: String { get }
}

extension AudiobookSortOrder: LibrarySortOption {
    var title: String {
        switch self {
        case .title: String(localized: "Title")
        case .author: String(localized: "Author")
        case .authorLastFirst: String(localized: "Author (Last, First)")
        case .published: String(localized: "Published")
        case .added: String(localized: "Added")
        case .duration: String(localized: "Duration")
        case .size: String(localized: "Size")
        case .lastUpdated: String(localized: "Last Played")
        }
    }

    /// Options offered in the library sort menu.
    static let menuOptions: [AudiobookSortOrder] = [.title, .author, .published, .added, .duration]
}

extension PodcastSortOrder: LibrarySortOption {
    var title: String {
        switch self {
        case .title: String(localized: "Title")
        case .author: String(localized: "Author")
        case .episodeCount: String(localized: "Episode Count")
        case .added: String(localized: "Added")
        }
    }
}

extension SeriesSortOrder: LibrarySortOption {
    var title: String {
        switch self {
        case .name: String(localized: "Name")
        case .bookCount: String(localized: "Books")
        case .added: String(localized: "Added")
        case .totalDuration: String(localized: "Duration")
        }
    }
}

extension AuthorSortOrder: LibrarySortOption {
    var title: String {
        switch self {
        case .firstLast: String(localized: "First Last")
        case .lastFirst: String(localized: "Last, First")
        case .bookCount: String(localized: "Books")
        case .added: String(localized: "Added")
        }
    }
}

extension NarratorSortOrder: LibrarySortOption {
    var title: String {
        switch self {
        case .name: String(localized: "Name")
        case .bookCount: String(localized: "Books")
        }
    }
}

extension ProgressFilter {
    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .notStarted: String(localized: "Not Started")
        case .inProgress: String(localized: "In Progress")
        case .finished: String(localized: "Finished")
        case .notFinished: String(localized: "Not Finished")
        }
    }
}

/// Persisted sort + direction for a list (stored through `ItemSettingsStore`, synced via iCloud KVS).
struct SortState<Sort: LibrarySortOption>: Equatable {
    var sort: Sort
    var direction: SortDirection

    @MainActor
    static func load(key: String, default sort: Sort, direction: SortDirection = .ascending) -> SortState {
        let (stored, storedDirection) = HearthData.shared.itemSettings.librarySort(for: key, default: sort)
        return SortState(sort: stored, direction: stored == sort && storedDirection == .ascending ? direction : storedDirection)
    }

    @MainActor
    func save(key: String) {
        HearthData.shared.itemSettings.setLibrarySort(sort, direction: direction, for: key)
    }
}

/// Sort section for an options menu: tapping the selected option flips the direction.
struct SortMenuSection<Sort: LibrarySortOption>: View {
    let options: [Sort]
    @Binding var state: SortState<Sort>

    var body: some View {
        Section("Sort By") {
            ForEach(options, id: \.self) { option in
                Button {
                    if state.sort == option {
                        state.direction.toggle()
                    } else {
                        state.sort = option
                    }
                } label: {
                    if state.sort == option {
                        Label(option.title, systemImage: state.direction.isDescending ? "chevron.down" : "chevron.up")
                    } else {
                        Text(option.title)
                    }
                }
            }
        }
    }
}

/// Grid / list picker for an options menu.
struct DisplayModeSection: View {
    @Binding var mode: DisplayMode

    var body: some View {
        Section {
            Picker("Display", selection: $mode) {
                Label("Grid", systemImage: "square.grid.2x2").tag(DisplayMode.grid)
                Label("List", systemImage: "list.bullet").tag(DisplayMode.list)
            }
            .pickerStyle(.inline)
        }
    }
}

/// Adaptive grid columns (min 150 on iPhone / 180 on iPad unless specified).
struct AdaptiveGrid {
    static func columns(compact: Bool, minimumCompact: CGFloat = 150, minimumRegular: CGFloat = 180) -> [GridItem] {
        [GridItem(.adaptive(minimum: compact ? minimumCompact : minimumRegular), spacing: 16, alignment: .top)]
    }
}

/// "123 audiobooks" footer.
struct CountFooter: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
    }
}

/// Spinner shown while the next page loads.
struct PageLoadingIndicator: View {
    var body: some View {
        ProgressView()
            .frame(maxWidth: .infinity)
            .padding()
    }
}

/// Shared paged-list body: initial loading/error/empty states, then `content`.
struct PagedContent<Element: Identifiable & Sendable, Content: View>: View {
    let loader: PagedLoader<Element>
    let emptyTitle: String
    let emptySymbol: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        if !loader.hasLoaded {
            LoadingView()
        } else if let error = loader.error, loader.items.isEmpty {
            ErrorView(message: error.userMessage) {
                await loader.reload()
            }
        } else if loader.items.isEmpty {
            EmptyStateView(title: emptyTitle, systemImage: emptySymbol)
        } else {
            content()
        }
    }
}
