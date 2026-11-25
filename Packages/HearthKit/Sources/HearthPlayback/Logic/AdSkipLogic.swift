import Foundation
import HearthModel

/// Decides when detected ads are skipped.
enum AdSkipLogic {
    /// Within this distance of an ad's end there's nothing left worth skipping.
    static let endMargin: TimeInterval = 1.5

    /// The ad playing at `time`, if any.
    static func segment(at time: TimeInterval, in segments: [AdSegment]) -> AdSegment? {
        segments.first { time >= $0.start && time < $0.end - endMargin }
    }

    /// The ad to skip at `time`: one that is playing and wasn't skipped (or deliberately sought into) before.
    /// `handled` holds the start times of such ads.
    static func segmentToSkip(at time: TimeInterval, in segments: [AdSegment], handled: Set<TimeInterval>) -> AdSegment? {
        guard let segment = segment(at: time, in: segments), !handled.contains(segment.start) else { return nil }
        return segment
    }
}
