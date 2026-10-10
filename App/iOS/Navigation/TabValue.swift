import HearthData
import HearthModel
import SwiftUI

/// Identity of a tab in the main `TabView` (also used as sidebar selection on iPad).
enum TabValue: Hashable, Codable, Sendable {
    case listenNow
    case search
    case settings
    /// A library tab (also used for pinned tabs, which may come from different libraries).
    case library(LibraryIdentifier, LibraryTab)
    /// Shown while no library is available yet (loading / connection failure).
    case noLibrary

    var customizationID: String {
        switch self {
        case .listenNow: "listen-now"
        case .search: "search"
        case .settings: "settings"
        case .noLibrary: "no-library"
        case .library(let library, let tab): "\(library.description)::\(tab.rawValue)"
        }
    }

    var library: LibraryIdentifier? {
        if case .library(let library, _) = self { library } else { nil }
    }

    var libraryTab: LibraryTab? {
        if case .library(_, let tab) = self { tab } else { nil }
    }
}

extension LibraryTab {
    var title: String {
        switch self {
        case .home: String(localized: "Home")
        case .library: String(localized: "Library")
        case .latest: String(localized: "Latest")
        case .series: String(localized: "Series")
        case .authors: String(localized: "Authors")
        case .narrators: String(localized: "Narrators")
        case .bookmarks: String(localized: "Bookmarks")
        case .collections: String(localized: "Collections")
        case .playlists: String(localized: "Playlists")
        case .downloaded: String(localized: "Downloaded")
        case .statistics: String(localized: "Statistics")
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .library: "books.vertical"
        case .latest: "clock"
        case .series: "rectangle.stack"
        case .authors: "person.2"
        case .narrators: "waveform"
        case .bookmarks: "bookmark"
        case .collections: "square.stack"
        case .playlists: "music.note.list"
        case .downloaded: "arrow.down.circle"
        case .statistics: "chart.bar"
        }
    }

    /// Tabs offered as shortcut rows at the top of the audiobook library.
    static let shortcutCandidates: [LibraryTab] = [.series, .authors, .narrators, .bookmarks, .collections, .playlists, .downloaded]
}

extension Library {
    /// Tabs shown on iPhone: user configuration or defaults (max 5).
    @MainActor
    var configuredTabs: [LibraryTab] {
        let configured = HearthData.shared.itemSettings.tabs(for: id) ?? LibraryTab.defaults(for: mediaType)
        let available = Set(LibraryTab.available(for: mediaType))
        return Array(configured.filter { available.contains($0) }.prefix(5))
    }
}
