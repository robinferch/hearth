import Foundation
import HearthModel

/// Pure filtering & sorting of podcast episodes (spec §6 "Episodes").
enum EpisodeListing {
    static func apply(_ settings: EpisodeListSettings, to episodes: [Episode], progress: (ItemIdentifier) -> ProgressEntity?, isDownloaded: (ItemIdentifier) -> Bool) -> [Episode] {
        let filtered = episodes.filter { episode in
            if let season = settings.season, normalized(episode.season) != normalized(season) {
                return false
            }
            if settings.downloadedOnly, !isDownloaded(episode.id) {
                return false
            }
            return matches(settings.filter, progress: progress(episode.id))
        }
        return sort(filtered, by: settings.sort, direction: settings.direction)
    }

    static func matches(_ filter: ProgressFilter, progress: ProgressEntity?) -> Bool {
        switch filter {
        case .all:
            true
        case .notStarted:
            progress == nil || (progress!.progress <= 0 && progress!.currentTime <= 0)
        case .inProgress:
            progress?.isInProgress ?? false
        case .finished:
            progress?.isFinished ?? false
        case .notFinished:
            !(progress?.isFinished ?? false)
        }
    }

    static func sort(_ episodes: [Episode], by order: EpisodeSortOrder, direction: SortDirection) -> [Episode] {
        let ascending = episodes.sorted { lhs, rhs in
            let result = compare(lhs, rhs, by: order)
            if result != .orderedSame {
                return result == .orderedAscending
            }
            // Stable, deterministic tie breakers.
            let released = compareDates(lhs.publishedAt ?? lhs.addedAt, rhs.publishedAt ?? rhs.addedAt)
            if released != .orderedSame {
                return released == .orderedAscending
            }
            return lhs.id.description < rhs.id.description
        }
        return direction == .descending ? ascending.reversed() : ascending
    }

    static func compare(_ lhs: Episode, _ rhs: Episode, by order: EpisodeSortOrder) -> ComparisonResult {
        switch order {
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name)
        case .index:
            let season = naturalCompare(normalized(lhs.season), normalized(rhs.season))
            if season != .orderedSame {
                return season
            }
            return naturalCompare(normalized(lhs.episode), normalized(rhs.episode))
        case .released:
            return compareDates(lhs.publishedAt ?? lhs.addedAt, rhs.publishedAt ?? rhs.addedAt)
        case .duration:
            if lhs.duration == rhs.duration { return .orderedSame }
            return lhs.duration < rhs.duration ? .orderedAscending : .orderedDescending
        }
    }

    /// Natural ("2" < "10") comparison; missing values sort last.
    static func naturalCompare(_ lhs: String?, _ rhs: String?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil): .orderedSame
        case (nil, _): .orderedDescending
        case (_, nil): .orderedAscending
        case (let lhs?, let rhs?): lhs.localizedStandardCompare(rhs)
        }
    }

    static func compareDates(_ lhs: Date?, _ rhs: Date?) -> ComparisonResult {
        let lhs = lhs ?? .distantPast
        let rhs = rhs ?? .distantPast
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// Seasons present in a list of episodes, naturally sorted.
    static func seasons(in episodes: [Episode]) -> [String] {
        Array(Set(episodes.compactMap { normalized($0.season) })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
