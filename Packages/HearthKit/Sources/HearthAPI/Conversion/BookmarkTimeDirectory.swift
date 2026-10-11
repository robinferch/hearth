import Foundation
import Synchronization

/// Remembers the exact (possibly fractional) time of server bookmarks.
///
/// `Bookmark.time` is whole seconds, but the server identifies a bookmark by the exact number it was created with
/// (other clients store fractions such as `123.6`). Updates and deletions must send that exact value, otherwise the
/// server answers 404.
final class BookmarkTimeDirectory: Sendable {
    private let times = Mutex<[String: Double]>([:])

    private static func key(itemID: String, second: Int) -> String {
        "\(itemID)#\(second)"
    }

    /// Whole seconds used as the local identity of a bookmark.
    static func second(of time: Double) -> Int {
        Int(time.rounded(.down))
    }

    func register(itemID: String, time: Double) {
        guard time.isFinite else { return }
        times.withLock { $0[Self.key(itemID: itemID, second: Self.second(of: time))] = time }
    }

    func register(_ payloads: [BookmarkPayload]) {
        for payload in payloads {
            register(itemID: payload.libraryItemID, time: payload.time)
        }
    }

    func remove(itemID: String, second: Int) {
        _ = times.withLock { $0.removeValue(forKey: Self.key(itemID: itemID, second: second)) }
    }

    /// The server's time for the bookmark at `second`, or `second` itself when it was never seen.
    func exactTime(itemID: String, second: Int) -> Double {
        times.withLock { $0[Self.key(itemID: itemID, second: second)] } ?? Double(second)
    }

    /// Path component for `DELETE …/bookmark/{time}` (`42`, `123.6`).
    static func pathComponent(_ time: Double) -> String {
        if time == time.rounded(), abs(time) < 1e15 {
            return String(Int(time))
        }
        return String(time)
    }
}
