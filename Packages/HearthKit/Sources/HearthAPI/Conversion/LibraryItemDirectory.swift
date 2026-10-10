import Foundation
import HearthModel
import Synchronization

/// Remembers which library (and media type) each library item id belongs to.
///
/// Media progress, bookmarks and some socket events only carry a `libraryItemId`, but an `ItemIdentifier`
/// needs the library id. Every converted library item is registered here; unknown ids are resolved with
/// `POST api/items/batch/get`.
final class LibraryItemDirectory: Sendable {
    struct Entry: Sendable, Hashable {
        var libraryID: String
        var isPodcast: Bool
    }

    private let entries = Mutex<[String: Entry]>([:])

    func register(itemID: String, libraryID: String, isPodcast: Bool) {
        guard !itemID.isEmpty, !libraryID.isEmpty else { return }
        entries.withLock { $0[itemID] = Entry(libraryID: libraryID, isPodcast: isPodcast) }
    }

    func entry(for itemID: String) -> Entry? {
        entries.withLock { $0[itemID] }
    }

    func unknown(_ itemIDs: some Sequence<String>) -> [String] {
        entries.withLock { entries in
            var seen = Set<String>()
            return itemIDs.filter { entries[$0] == nil && seen.insert($0).inserted }
        }
    }
}
