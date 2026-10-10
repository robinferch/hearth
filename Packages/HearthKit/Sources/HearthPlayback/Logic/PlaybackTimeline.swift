import Foundation
import HearthModel

/// Maps absolute item time onto an ordered list of audio tracks (multi-file audiobooks).
struct PlaybackTimeline: Hashable, Sendable {
    /// Tracks sorted by offset.
    let tracks: [AudioTrack]

    init(tracks: [AudioTrack]) {
        self.tracks = tracks.sorted { lhs, rhs in
            lhs.offset == rhs.offset ? lhs.index < rhs.index : lhs.offset < rhs.offset
        }
    }

    static let empty = PlaybackTimeline(tracks: [])

    var isEmpty: Bool { tracks.isEmpty }

    /// `last.offset + last.duration`.
    var duration: TimeInterval {
        guard let last = tracks.last else { return 0 }
        return last.offset + last.duration
    }

    /// Array position of the track that contains `time` (the last track whose offset is ≤ time).
    func position(containing time: TimeInterval) -> Int? {
        guard !tracks.isEmpty else { return nil }
        var low = 0
        var high = tracks.count - 1
        var result = 0
        while low <= high {
            let mid = (low + high) / 2
            if tracks[mid].offset <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    /// Time inside the track at `position` for an absolute item time.
    func localTime(for time: TimeInterval, at position: Int) -> TimeInterval {
        let track = tracks[position]
        let local = max(0, time - track.offset)
        return track.duration > 0 ? min(local, track.duration) : local
    }

    /// Absolute item time for a time inside the track at `position`.
    func absoluteTime(local: TimeInterval, at position: Int) -> TimeInterval {
        tracks[position].offset + max(0, local)
    }

    /// Decides how the player has to move to reach `time`.
    /// - Parameters:
    ///   - loadedPositions: Track positions currently enqueued in the player, current track first.
    ///   - totalDuration: Item duration (defaults to the timeline duration).
    func seekPlan(to time: TimeInterval, loadedPositions: [Int], totalDuration: TimeInterval? = nil) -> SeekPlan {
        let total = totalDuration ?? duration
        let target = max(0, time)
        guard !tracks.isEmpty, target < total, let position = position(containing: target) else {
            return .finish
        }
        let local = localTime(for: target, at: position)
        guard let current = loadedPositions.first else {
            return .rebuild(fromPosition: position, localTime: local)
        }
        if position == current {
            return .withinCurrent(localTime: local)
        }
        if let steps = loadedPositions.firstIndex(of: position), steps > 0 {
            return .advance(steps: steps, localTime: local)
        }
        return .rebuild(fromPosition: position, localTime: local)
    }
}

enum SeekPlan: Equatable, Sendable {
    /// Target is at or beyond the end → item finished.
    case finish
    /// Seek inside the current player item.
    case withinCurrent(localTime: TimeInterval)
    /// Advance the queue player `steps` items, then seek.
    case advance(steps: Int, localTime: TimeInterval)
    /// Replace the player items starting at `fromPosition`, then seek.
    case rebuild(fromPosition: Int, localTime: TimeInterval)
}
