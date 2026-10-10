import Foundation

/// Smart rewind rules (spec §6).
enum SmartRewind {
    static let shortPauseThreshold: TimeInterval = 30
    static let longPauseThreshold: TimeInterval = 10 * 60
    static let shortRewind: TimeInterval = 10
    static let longRewind: TimeInterval = 30

    /// Rewind when resuming after a pause of `pausedFor` seconds.
    static func resumeRewind(pausedFor: TimeInterval) -> TimeInterval {
        if pausedFor > longPauseThreshold {
            return longRewind
        }
        if pausedFor > shortPauseThreshold {
            return shortRewind
        }
        return 0
    }

    /// Rewind on a cold start based on the progress' last update.
    static func coldStartRewind(lastUpdate: Date?, now: Date) -> TimeInterval {
        guard let lastUpdate, lastUpdate != .distantPast else { return 0 }
        return now.timeIntervalSince(lastUpdate) >= longPauseThreshold ? longRewind : 0
    }

    /// Applies `rewind` to `time`. Short rewinds never cross the current chapter start.
    static func apply(_ rewind: TimeInterval, to time: TimeInterval, chapterStart: TimeInterval?) -> TimeInterval {
        guard rewind > 0 else { return time }
        var target = max(0, time - rewind)
        if rewind <= shortRewind, let chapterStart, chapterStart <= time {
            target = max(target, chapterStart)
        }
        return target
    }
}
