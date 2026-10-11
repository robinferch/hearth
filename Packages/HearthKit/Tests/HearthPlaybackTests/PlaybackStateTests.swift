import Foundation
import Testing
@testable import HearthPlayback

@Suite struct InterruptionLogicTests {
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test func playingOrIntendingCounts() {
        #expect(InterruptionLogic.wasPlaying(isPlaying: true, intendsToPlay: false, systemPausedAt: nil, now: now))
        #expect(InterruptionLogic.wasPlaying(isPlaying: false, intendsToPlay: true, systemPausedAt: nil, now: now))
        #expect(!InterruptionLogic.wasPlaying(isPlaying: false, intendsToPlay: false, systemPausedAt: nil, now: now))
    }

    /// The player reported the system pause before the interruption notification arrived.
    @Test func recentSystemPauseCounts() {
        #expect(InterruptionLogic.wasPlaying(isPlaying: false, intendsToPlay: false, systemPausedAt: now.addingTimeInterval(-0.2), now: now))
        #expect(InterruptionLogic.wasPlaying(isPlaying: false, intendsToPlay: false, systemPausedAt: now.addingTimeInterval(-InterruptionLogic.systemPauseWindow), now: now))
    }

    @Test func oldSystemPauseDoesNotCount() {
        #expect(!InterruptionLogic.wasPlaying(isPlaying: false, intendsToPlay: false, systemPausedAt: now.addingTimeInterval(-10), now: now))
        #expect(!InterruptionLogic.wasPlaying(isPlaying: false, intendsToPlay: false, systemPausedAt: now.addingTimeInterval(5), now: now))
    }
}

@MainActor
@Suite struct StartPauseTests {
    /// Pausing while an item is starting must stick; play/pause toggles that request.
    @Test func pauseDuringStartIsRemembered() {
        let player = AudioPlayer()
        player.startingRunID = UUID()
        #expect(player.willPlayAfterStart)

        player.togglePlayPause()
        #expect(player.pausedDuringStart)
        #expect(!player.intendsToPlay)
        #expect(!player.willPlayAfterStart)

        player.togglePlayPause()
        #expect(!player.pausedDuringStart)
        #expect(player.intendsToPlay)
        #expect(player.willPlayAfterStart)
    }

    @Test func pauseWithoutStartDoesNotLeak() {
        let player = AudioPlayer()
        player.pause()
        #expect(!player.pausedDuringStart)
        #expect(!player.willPlayAfterStart)
    }

    @Test func userPauseClearsSystemPause() {
        let player = AudioPlayer()
        player.systemPausedAt = .now
        player.resumeAfterInterruption = true
        player.pause()
        #expect(player.systemPausedAt == nil)
        #expect(!player.resumeAfterInterruption)
    }
}
