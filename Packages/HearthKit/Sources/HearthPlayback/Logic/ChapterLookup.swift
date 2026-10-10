import Foundation
import HearthModel

/// Chapter index math shared by the player, Now Playing and the sleep timer.
enum ChapterLookup {
    /// Seeking exactly to a chapter start often reports a time a few ms before it.
    static let tolerance: TimeInterval = 0.05

    /// Threshold for "previous chapter": within the first 3 s go to the previous chapter, else restart this one.
    static let restartThreshold: TimeInterval = 3

    /// Index of the chapter active at `time` (last chapter starting at or before `time`; 0 before the first).
    static func index(of time: TimeInterval, in chapters: [Chapter]) -> Int? {
        guard !chapters.isEmpty else { return nil }
        let probe = time + tolerance
        var low = 0
        var high = chapters.count - 1
        var result = 0
        while low <= high {
            let mid = (low + high) / 2
            if chapters[mid].start <= probe {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    /// Sorts chapters and repairs missing/invalid end times.
    static func normalized(_ chapters: [Chapter], duration: TimeInterval) -> [Chapter] {
        let sorted = chapters.sorted { $0.start < $1.start }
        return sorted.enumerated().map { offset, chapter in
            var chapter = chapter
            let nextStart = offset + 1 < sorted.count ? sorted[offset + 1].start : nil
            if chapter.end <= chapter.start {
                chapter.end = nextStart ?? max(duration, chapter.start)
            }
            return chapter
        }
    }

    /// Target of "previous chapter": start of the current chapter, or the previous one when within the first 3 s.
    static func previousTarget(from time: TimeInterval, in chapters: [Chapter]) -> TimeInterval? {
        guard let index = index(of: time, in: chapters) else { return nil }
        let chapter = chapters[index]
        if time - chapter.start > restartThreshold || index == 0 {
            return chapter.start
        }
        return chapters[index - 1].start
    }

    /// Start of the next chapter, `nil` when in the last chapter.
    static func nextStart(from time: TimeInterval, in chapters: [Chapter]) -> TimeInterval? {
        guard let index = index(of: time, in: chapters), index + 1 < chapters.count else { return nil }
        return chapters[index + 1].start
    }

    /// Number of chapter ends until (and including) the end of the chapter at `targetIndex`.
    static func chaptersRemaining(until targetIndex: Int, currentIndex: Int?) -> Int {
        max(1, targetIndex - (currentIndex ?? 0) + 1)
    }
}
