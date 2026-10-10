import Foundation
import HearthModel

/// Playback rate rules (spec §5).
enum PlaybackRateMath {
    static let range: ClosedRange<Double> = 0.25...4.0
    static let tolerance = 0.001

    /// Clamps to 0.25–4.0 and rounds to two decimals.
    static func clamp(_ rate: Double) -> Double {
        guard rate.isFinite else { return 1 }
        let clamped = min(max(rate, range.lowerBound), range.upperBound)
        return (clamped * 100).rounded() / 100
    }

    /// The next preset after `rate` (wrapping to the smallest).
    static func next(after rate: Double, presets: [Double]) -> Double {
        let sorted = Array(Set(presets.map(clamp))).sorted()
        guard let first = sorted.first else { return 1 }
        return sorted.first { $0 > rate + tolerance } ?? first
    }

    /// Grouping identifiers consulted for rate / sleep timer lookups, in priority order:
    /// collection the item was started from > series > podcast.
    static func groupingCandidates(for item: AnyPlayableItem, origin: PlaybackOrigin) -> [ItemIdentifier] {
        var result: [ItemIdentifier] = []
        if case .collection(let id) = origin {
            result.append(id)
        }
        if case .series(let id) = origin {
            result.append(id)
        }
        switch item {
        case .audiobook(let audiobook):
            for fragment in audiobook.series {
                guard let seriesID = fragment.id else { continue }
                let id = ItemIdentifier(kind: .series, connectionID: audiobook.id.connectionID, libraryID: audiobook.id.libraryID, primaryID: seriesID)
                if !result.contains(id) {
                    result.append(id)
                }
            }
        case .episode(let episode):
            if let podcast = episode.id.podcastIdentifier, !result.contains(podcast) {
                result.append(podcast)
            }
        }
        if case .podcast(let id) = origin, !result.contains(id) {
            result.append(id)
        }
        return result
    }
}
