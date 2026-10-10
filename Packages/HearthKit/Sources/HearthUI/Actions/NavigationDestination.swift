import Foundation
import HearthData
import HearthModel

/// Every push destination in the app's navigation stacks.
///
/// The app maps these with `.navigationDestination(for: NavigationDestination.self)`; shared
/// components (rows, context menus) only create values.
public enum NavigationDestination: Hashable, Sendable {
    /// Detail page of any item (audiobook, podcast, episode, series, author, narrator, collection, playlist).
    case item(ItemIdentifier)
    /// Author looked up by name (audiobooks only carry author names).
    case author(name: String, library: LibraryIdentifier)
    /// Narrator looked up by name.
    case narrator(name: String, library: LibraryIdentifier)
    /// Series without a known id, looked up by name.
    case series(name: String, library: LibraryIdentifier)
    /// Full grid of a home shelf.
    case homeRow(HomeRow, library: LibraryIdentifier)
    /// All episodes of a podcast.
    case allEpisodes(podcast: ItemIdentifier)
    /// A library tab pushed from a shortcut row (e.g. "Series" inside the Library tab).
    case libraryTab(LibraryTab, library: LibraryIdentifier)
    /// Audiobooks of a library filtered by genre / tag / … .
    case filteredAudiobooks(LibraryItemFilter, title: String, library: LibraryIdentifier)
}

public extension NavigationDestination {
    /// Destinations for the series of an audiobook.
    static func series(of book: Audiobook) -> [(title: String, destination: NavigationDestination)] {
        book.series.map { fragment in
            if let id = fragment.id {
                (fragment.formatted, .item(ItemIdentifier(kind: .series, connectionID: book.id.connectionID, libraryID: book.id.libraryID, primaryID: id)))
            } else {
                (fragment.formatted, .series(name: fragment.name, library: book.id.library))
            }
        }
    }
}
