import Foundation
import HearthModel

/// Remembers which episodes of a podcast library were already seen, to notify about new ones.
///
/// The first check of a library only records a baseline – enabling notifications must not announce the whole
/// backlog. Episodes released/added long ago (e.g. re-imported) are never announced.
public struct NewEpisodeTracker: Sendable {
    nonisolated(unsafe) private let defaults: UserDefaults
    /// Episodes older than this are recorded silently.
    public var maximumAge: TimeInterval = 14 * 24 * 3600
    /// Remembered ids per library.
    public var capacity = 500

    private static let prefix = "notifications.seenEpisodes."

    public init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
    }

    /// Records `episodes` (the library's most recent episodes) as seen and returns the ones that are new since the
    /// last check, newest first. Empty on the first check of a library.
    public func register(_ episodes: [Episode], in library: LibraryIdentifier, now: Date = .now) -> [Episode] {
        let key = Self.prefix + library.description
        let stored = defaults.stringArray(forKey: key)
        let ids = episodes.map(\.id.description)
        guard let stored else {
            defaults.set(Array(ids.prefix(capacity)), forKey: key)
            return []
        }
        let seen = Set(stored)
        let new = episodes.filter { episode in
            guard !seen.contains(episode.id.description) else { return false }
            let date = episode.publishedAt ?? episode.addedAt ?? now
            return now.timeIntervalSince(date) <= maximumAge
        }
        // Newest ids first, then the previously seen ones still fitting.
        var merged = ids
        var included = Set(ids)
        for id in stored where !included.contains(id) {
            merged.append(id)
            included.insert(id)
        }
        defaults.set(Array(merged.prefix(capacity)), forKey: key)
        return new.sorted { ($0.publishedAt ?? $0.addedAt ?? .distantPast) > ($1.publishedAt ?? $1.addedAt ?? .distantPast) }
    }

    /// Forgets all baselines (e.g. when notifications are turned on, so the next check starts fresh).
    public func reset() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.prefix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// Whether a baseline exists for `library`.
    public func hasBaseline(for library: LibraryIdentifier) -> Bool {
        defaults.stringArray(forKey: Self.prefix + library.description) != nil
    }
}
