import HearthData
import HearthModel
import HearthUI
import OSLog
import SwiftUI

/// Sheets presented from the root of a scene.
enum AppSheet: Identifiable, Hashable {
    case settings
    case listenNow
    case addConnection
    case addTo(ItemIdentifier)
    case customizeTabs(LibraryIdentifier)
    case pinnedTabs

    var id: String {
        switch self {
        case .settings: "settings"
        case .listenNow: "listen-now"
        case .addConnection: "add-connection"
        case .addTo(let id): "add-to-\(id)"
        case .customizeTabs(let library): "customize-\(library)"
        case .pinnedTabs: "pinned-tabs"
        }
    }
}

/// Per-scene navigation state: selected tab, one navigation path per tab, current library, sheets.
@MainActor
@Observable
final class Navigator {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hearth", category: "Navigator")

    var selectedTab: TabValue = .noLibrary {
        didSet {
            if case .library(let library, _) = selectedTab, !isPinnedMode {
                currentLibrary = library
            }
            if selectedTab != .noLibrary {
                Self.store(selectedTab, key: Keys.lastTab)
            }
        }
    }

    /// Navigation path for each tab.
    var paths: [TabValue: [NavigationDestination]] = [:]

    /// Library whose tabs are shown on iPhone.
    var currentLibrary: LibraryIdentifier? {
        didSet { Self.store(currentLibrary, key: Keys.currentLibrary) }
    }

    /// iPhone shows the user's pinned tabs instead of the current library's tabs.
    var isPinnedMode: Bool {
        didSet { UserDefaults.standard.set(isPinnedMode, forKey: Keys.pinnedMode) }
    }

    var sheet: AppSheet?

    /// Search text (shared by the search tab and ⌘F / `hearth://search`).
    var searchText = ""
    var isSearchPresented = false

    /// Bookmark note prompt (⌘B / player).
    var isBookmarkPromptPresented = false

    init() {
        currentLibrary = Self.load(LibraryIdentifier.self, key: Keys.currentLibrary)
        isPinnedMode = UserDefaults.standard.bool(forKey: Keys.pinnedMode)
        if let last = Self.load(TabValue.self, key: Keys.lastTab) {
            selectedTab = last
        }
    }

    // MARK: Paths

    func path(for tab: TabValue) -> Binding<[NavigationDestination]> {
        Binding(
            get: { self.paths[tab] ?? [] },
            set: { self.paths[tab] = $0 }
        )
    }

    /// The tab whose navigation stack is on screen. Offline mode shows a single stack (`OfflineView`, bound to
    /// `.noLibrary`) regardless of the restored tab selection.
    var visibleTab: TabValue {
        HearthData.shared.connections.isOffline ? .noLibrary : selectedTab
    }

    /// Pushes onto the visible tab's stack. The iPad Settings tab has no item stack, so pushes from there
    /// (e.g. "Go to…" in the mini player) switch to Listen Now first.
    func push(_ destination: NavigationDestination) {
        if visibleTab == .settings {
            selectedTab = .listenNow
        }
        paths[visibleTab, default: []].append(destination)
    }

    func popToRoot() {
        paths[visibleTab] = []
    }

    // MARK: Tabs

    /// Tabs shown in the compact (iPhone) tab bar, excluding search.
    func compactTabs(connections: ConnectionStore, pinned: [PinnedTab]) -> [TabValue] {
        if isPinnedMode, !pinned.isEmpty {
            return pinned.prefix(5).compactMap { pin in
                connections.library(pin.library) == nil ? nil : .library(pin.library, pin.tab)
            }
        }
        guard let library = resolvedLibrary(connections: connections) else { return [] }
        return library.configuredTabs.map { .library(library.id, $0) }
    }

    /// The current library, falling back to the first available one.
    func resolvedLibrary(connections: ConnectionStore) -> Library? {
        if let currentLibrary, let library = connections.library(currentLibrary) {
            return library
        }
        return connections.allLibraries.first
    }

    /// Whether the main UI currently shows the compact tab bar (updated by `validateSelection`).
    @ObservationIgnored private var isCompactLayout = true

    /// Makes sure the selection points at an existing tab.
    func validateSelection(connections: ConnectionStore, pinned: [PinnedTab], compact: Bool) {
        isCompactLayout = compact
        switch selectedTab {
        case .search, .settings, .listenNow:
            if compact, selectedTab != .search {
                selectedTab = compactTabs(connections: connections, pinned: pinned).first ?? .noLibrary
            }
        case .noLibrary, .library:
            if compact {
                let tabs = compactTabs(connections: connections, pinned: pinned)
                if !tabs.contains(selectedTab) {
                    selectedTab = tabs.first ?? .noLibrary
                }
            } else if case .library(let library, _) = selectedTab, connections.library(library) != nil {
                return
            } else if let first = connections.allLibraries.first {
                selectedTab = .library(first.id, .home)
            } else {
                selectedTab = .noLibrary
            }
        }
    }

    /// Switches the iPhone tab bar to another library.
    func select(library: Library) {
        isPinnedMode = false
        currentLibrary = library.id
        let tab = library.configuredTabs.first ?? .home
        selectedTab = .library(library.id, tab)
    }

    // MARK: External navigation

    /// Switches to a suitable tab of the item's library and pushes the item.
    func open(_ id: ItemIdentifier, connections: ConnectionStore) {
        let destination: NavigationDestination = .item(id)
        if connections.isOffline {
            push(destination)
            return
        }
        if case .library(let library, _) = selectedTab, library == id.library {
            push(destination)
            return
        }
        let pinned = HearthData.shared.itemSettings.pinnedTabs
        if isCompactLayout, isPinnedMode, !pinned.isEmpty {
            // Only tabs in the pinned tab bar can be selected: prefer one of the item's library, else stay put.
            if let tab = compactTabs(connections: connections, pinned: pinned).first(where: { $0.library == id.library }) {
                selectedTab = tab
                paths[tab] = [destination]
            } else {
                push(destination)
            }
            return
        }
        if let library = connections.library(id.library) {
            if !isPinnedMode {
                currentLibrary = library.id
            }
            let tab = library.configuredTabs.first ?? .home
            selectedTab = .library(library.id, tab)
            paths[selectedTab] = [destination]
        } else {
            Self.logger.notice("Library of \(id.description, privacy: .public) is not available; pushing on the current tab")
            push(destination)
        }
    }

    /// Pushes the statistics screen of the current library's server onto the selected tab.
    func showStatistics(connections: ConnectionStore) {
        guard let library = resolvedLibrary(connections: connections) else { return }
        if paths[selectedTab]?.last == .libraryTab(.statistics, library: library.id) {
            return
        }
        push(.libraryTab(.statistics, library: library.id))
    }

    func showSearch(query: String?) {
        if let query {
            searchText = query
        }
        selectedTab = .search
        isSearchPresented = true
    }

    // MARK: Persistence

    private enum Keys {
        static let currentLibrary = "navigation.currentLibrary"
        static let lastTab = "navigation.lastTab"
        static let pinnedMode = "navigation.pinnedMode"
    }

    private static func store<T: Encodable>(_ value: T?, key: String) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

extension FocusedValues {
    /// The key window's navigator (used by menu-bar commands / keyboard shortcuts).
    @Entry var navigator: Navigator?
}
