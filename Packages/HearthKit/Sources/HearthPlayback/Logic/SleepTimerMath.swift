import Foundation
import HearthModel

/// User preferences relevant to extending a sleep timer.
struct SleepTimerExtendConfiguration: Hashable, Sendable {
    var extendByPrevious: Bool
    var extendMinutes: Int
    var extendChapters: Int
}

/// Pure sleep timer arithmetic (no clocks, no player). All times are passed in.
enum SleepTimerMath {
    /// Linear fade-out length at the end of a timer.
    static let fadeDuration: TimeInterval = 10
    /// Window after expiry in which pressing play (or shaking) restores & extends the timer.
    static let restoreWindow: TimeInterval = 10
    /// Smart rewind applied when the timer expires.
    static let expiryRewind: TimeInterval = 10
    static let maximumChapters = 42

    static func state(for preset: SleepTimerPreset, now: Date) -> SleepTimerState {
        switch preset {
        case .minutes(let minutes):
            let length = TimeInterval(max(1, minutes) * 60)
            return .duration(deadline: now.addingTimeInterval(length), original: length)
        case .chapters(let count):
            let count = min(max(1, count), maximumChapters)
            return .chapters(remaining: count, original: count)
        }
    }

    /// Remaining seconds of a duration timer. While paused (`pausedAt` set) the remaining time is frozen.
    static func remaining(of state: SleepTimerState, now: Date, pausedAt: Date?) -> TimeInterval? {
        guard case .duration(let deadline, _) = state else { return nil }
        return max(0, deadline.timeIntervalSince(pausedAt ?? now))
    }

    /// Shifts the deadline by the time spent paused.
    static func resumed(_ state: SleepTimerState, pausedAt: Date, now: Date) -> SleepTimerState {
        guard case .duration(let deadline, let original) = state else { return state }
        let pause = max(0, now.timeIntervalSince(pausedAt))
        return .duration(deadline: deadline.addingTimeInterval(pause), original: original)
    }

    /// Seconds (duration timers) added by "Extend".
    static func extensionSeconds(original: TimeInterval, configuration: SleepTimerExtendConfiguration) -> TimeInterval {
        if configuration.extendByPrevious, original > 0 {
            return original
        }
        return TimeInterval(max(1, configuration.extendMinutes) * 60)
    }

    /// Chapters (chapter timers) added by "Extend".
    static func extensionChapters(original: Int, configuration: SleepTimerExtendConfiguration) -> Int {
        if configuration.extendByPrevious, original > 0 {
            return original
        }
        return min(max(1, configuration.extendChapters), maximumChapters)
    }

    static func extended(_ state: SleepTimerState, configuration: SleepTimerExtendConfiguration) -> SleepTimerState {
        switch state {
        case .duration(let deadline, let original):
            let amount = extensionSeconds(original: original, configuration: configuration)
            return .duration(deadline: deadline.addingTimeInterval(amount), original: original)
        case .chapters(let remaining, let original):
            let amount = extensionChapters(original: original, configuration: configuration)
            return .chapters(remaining: remaining + amount, original: original)
        }
    }

    /// A fresh timer after expiry (play-to-extend / shake-to-extend).
    static func restarted(after expired: SleepTimerState, configuration: SleepTimerExtendConfiguration, now: Date) -> SleepTimerState {
        switch expired {
        case .duration(_, let original):
            let amount = extensionSeconds(original: original, configuration: configuration)
            return .duration(deadline: now.addingTimeInterval(amount), original: original)
        case .chapters(_, let original):
            let amount = extensionChapters(original: original, configuration: configuration)
            return .chapters(remaining: amount, original: original)
        }
    }

    /// ±1 minute / ±1 chapter per `delta` step. Returns `nil` when the timer should be cancelled.
    static func adjusted(_ state: SleepTimerState, by delta: Int, now: Date, pausedAt: Date?) -> SleepTimerState? {
        switch state {
        case .duration(let deadline, let original):
            let newDeadline = deadline.addingTimeInterval(TimeInterval(delta * 60))
            let remaining = newDeadline.timeIntervalSince(pausedAt ?? now)
            return remaining < 1 ? nil : .duration(deadline: newDeadline, original: original)
        case .chapters(let remaining, let original):
            let newRemaining = remaining + delta
            return newRemaining < 1 ? nil : .chapters(remaining: min(newRemaining, maximumChapters), original: original)
        }
    }

    /// Volume (0...1) for the linear fade during the final seconds.
    static func fadeVolume(timeRemaining: TimeInterval) -> Float {
        guard timeRemaining < fadeDuration else { return 1 }
        return Float(max(0, min(1, timeRemaining / fadeDuration)))
    }

    enum ChapterTransition: Equatable, Sendable {
        case none
        case decremented(SleepTimerState)
        /// The timer's last chapter ended (overshoot) → expire now.
        case expire
    }

    /// Chapter timers count down when playback moves from one chapter into the very next one.
    static func chapterTransition(_ state: SleepTimerState, from old: Int?, to new: Int?) -> ChapterTransition {
        guard case .chapters(let remaining, let original) = state, let old, let new, new == old + 1 else {
            return .none
        }
        if remaining <= 1 {
            return .expire
        }
        return .decremented(.chapters(remaining: remaining - 1, original: original))
    }
}
