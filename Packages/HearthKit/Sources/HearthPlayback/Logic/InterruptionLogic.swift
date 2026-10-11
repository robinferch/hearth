import Foundation

/// Decides whether playback was running when the system interrupted it.
///
/// The player's `timeControlStatus` observation can report the system pause *before* the audio session's
/// interruption notification (or a stream failure) arrives. At that point `isPlaying`/`intendsToPlay` are already
/// cleared, so a recent system pause also counts as "was playing".
enum InterruptionLogic {
    /// How long after a system pause an interruption or stream failure is still attributed to it.
    static let systemPauseWindow: TimeInterval = 3

    static func wasPlaying(isPlaying: Bool, intendsToPlay: Bool, systemPausedAt: Date?, now: Date) -> Bool {
        if isPlaying || intendsToPlay {
            return true
        }
        guard let systemPausedAt else { return false }
        let elapsed = now.timeIntervalSince(systemPausedAt)
        return elapsed >= 0 && elapsed <= systemPauseWindow
    }
}
