import AVFoundation
import Foundation
import HearthData
import HearthModel

/// Play / pause / stop, chapters, rate, skip-tap combining.
extension AudioPlayer {
    func performResume() {
        guard currentItem != nil else {
            if lastPlayedItemID != nil {
                Task {
                    do {
                        try await resumeLastPlayed()
                    } catch {
                        logger.error("Resuming the last played item failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            return
        }

        restoreSleepTimerOnPlayIfNeeded()

        var rewind: TimeInterval = 0
        if AppSettings.shared.smartRewind, let lastPauseDate {
            rewind = SmartRewind.resumeRewind(pausedFor: Date.now.timeIntervalSince(lastPauseDate))
        }
        lastPauseDate = nil
        resumeAfterInterruption = false
        intendsToPlay = true
        updateBuffering()

        let needsItems = player?.items().isEmpty ?? true
        Task {
            if needsItems {
                // Items were dropped (failure / media services reset): reload at the current position.
                await rebuildPlayerItems(refreshHeaders: !isPlayingLocalFiles)
            }
            if rewind > 0 {
                await seekInternal(to: SmartRewind.apply(rewind, to: currentTime, chapterStart: currentChapter?.start))
            }
            await activateAndPlay()
        }
    }

    func performPause() {
        intendsToPlay = false
        resumeAfterInterruption = false
        player?.pause()
        if lastPauseDate == nil {
            lastPauseDate = .now
        }
        isBuffering = false
        syncPlayingState()
    }

    func performStop() async {
        guard currentItem != nil else { return }
        performCancelSleepTimer()
        finalizeCurrentRun(finished: false)
        runID = UUID()
        resetToIdle()
    }

    func performNextChapter() async {
        if let target = ChapterLookup.nextStart(from: currentTime, in: chapters) {
            await seekInternal(to: target)
        } else if chapters.isEmpty {
            await skipForward()
        } else if !queue.isEmpty || !upNext.isEmpty {
            await performAdvance()
        }
    }

    func performPreviousChapter() async {
        if let target = ChapterLookup.previousTarget(from: currentTime, in: chapters) {
            await seekInternal(to: target)
        } else {
            await skipBackward()
        }
    }

    // MARK: Rate

    func applyPlaybackRate(_ rate: Double, save: Bool) {
        let rate = PlaybackRateMath.clamp(rate)
        playbackRate = rate
        if let player {
            player.defaultRate = Float(rate)
            if player.timeControlStatus != .paused {
                player.rate = Float(rate)
            }
        }
        if save, let item = currentItem {
            HearthData.shared.itemSettings.setPlaybackRate(rate, for: item.id)
        }
        updateNowPlayingInfo()
    }

    /// Fine-step the rate up/down using the configured step sizes.
    public func stepPlaybackRate(up: Bool) {
        let settings = AppSettings.shared
        setPlaybackRate(playbackRate + (up ? settings.playbackRateStepUp : -settings.playbackRateStepDown))
    }

    // MARK: Skip tap combining

    /// Registers a tap on the skip button. Taps within 0.3 s (then 0.7 s) are combined into one seek;
    /// `pendingSkipTotal` holds the running total for the badge.
    public func registerSkipTap(forward: Bool) {
        let settings = AppSettings.shared
        let amount = forward ? TimeInterval(settings.skipForwardInterval) : -TimeInterval(settings.skipBackwardInterval)
        let deadline = skipCombiner.registerTap(amount: amount, at: .now)
        pendingSkipTotal = skipCombiner.total
        skipCombinerTask?.cancel()
        skipCombinerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            guard let self, !Task.isCancelled, let total = self.skipCombiner.flush(at: .now) else { return }
            self.pendingSkipTotal = nil
            await self.seekInternal(to: max(0, self.currentTime + total))
        }
    }

    // MARK: Token refresh / lifecycle hooks

    /// Rebuilds streaming player items with fresh headers after a token refresh or connection change.
    public func connectionDidRefreshCredentials(_ connectionID: ConnectionID) async {
        guard let item = currentItem, item.id.connectionID == connectionID, !isPlayingLocalFiles else { return }
        await rebuildPlayerItems(refreshHeaders: true)
    }

    /// Reports progress before the app is suspended. Called automatically on iOS/watchOS; may also be
    /// called from a SwiftUI `scenePhase` change.
    public func appDidEnterBackground() {
        updateSnapshot(force: true)
        guard let reporter else { return }
        reporter.report(currentTime: currentTime)
        let activity = BackgroundActivity(name: "Report listening progress")
        Task {
            await reporter.flush()
            activity.end()
        }
    }

    /// Best-effort final report when the process terminates.
    public func appWillTerminate() {
        guard currentItem != nil else { return }
        finalizeCurrentRun(finished: false)
    }
}
