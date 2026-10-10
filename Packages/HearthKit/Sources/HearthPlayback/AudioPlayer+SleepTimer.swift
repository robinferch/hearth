import AVFoundation
import Foundation
import HearthData
import HearthModel

/// Sleep timer (spec §4).
extension AudioPlayer {
    var sleepTimerConfiguration: SleepTimerExtendConfiguration {
        let settings = AppSettings.shared
        return SleepTimerExtendConfiguration(
            extendByPrevious: settings.sleepTimerExtendByPrevious,
            extendMinutes: settings.sleepTimerExtendMinutes,
            extendChapters: settings.sleepTimerExtendChapters
        )
    }

    /// Replaces the timer (or clears it with `nil`).
    func applySleepTimer(_ state: SleepTimerState?) {
        cancelPendingChapterSleep()
        restoreVolumeAfterFade()
        sleepTimer = state
        if state != nil {
            sleepTimerExpiredAt = nil
            lastExpiredSleepTimer = nil
        }
        if case .duration? = state {
            // While paused the timer doesn't run.
            sleepTimerPausedAt = isPlaying ? nil : .now
            startSleepTimerLoop()
        } else {
            sleepTimerTask?.cancel()
            sleepTimerTask = nil
            sleepTimerPausedAt = nil
            sleepTimerRemaining = nil
        }
        sleepTimerDidChange(expired: false)
    }

    func sleepTimerDidChange(expired: Bool) {
        post(Self.sleepTimerChangedNotification, itemID: currentItem?.id, extra: [Self.sleepTimerExpiredKey: expired])
        updateSnapshot(force: true)
    }

    func performSetSleepTimer(endOf chapter: Chapter) {
        guard let index = chapters.firstIndex(where: { $0.id == chapter.id && $0.start == chapter.start }) ?? chapters.firstIndex(where: { $0.start == chapter.start }) else {
            applySleepTimer(SleepTimerMath.state(for: .endOfChapter, now: .now))
            return
        }
        let remaining = ChapterLookup.chaptersRemaining(until: index, currentIndex: currentChapterIndex)
        applySleepTimer(.chapters(remaining: remaining, original: remaining))
    }

    func performExtendSleepTimer() {
        if let sleepTimer {
            self.sleepTimer = SleepTimerMath.extended(sleepTimer, configuration: sleepTimerConfiguration)
            restoreVolumeAfterFade()
            cancelPendingChapterSleep()
            refreshSleepTimerRemaining()
            sleepTimerDidChange(expired: false)
        } else if let expired = lastExpiredSleepTimer {
            applySleepTimer(SleepTimerMath.restarted(after: expired, configuration: sleepTimerConfiguration, now: .now))
        }
    }

    func performAdjustSleepTimer(by delta: Int) {
        guard let sleepTimer, delta != 0 else { return }
        guard let adjusted = SleepTimerMath.adjusted(sleepTimer, by: delta, now: .now, pausedAt: sleepTimerPausedAt) else {
            performCancelSleepTimer()
            return
        }
        self.sleepTimer = adjusted
        if delta > 0 {
            restoreVolumeAfterFade()
            cancelPendingChapterSleep()
        }
        refreshSleepTimerRemaining()
        sleepTimerDidChange(expired: false)
    }

    func performCancelSleepTimer() {
        guard sleepTimer != nil else { return }
        applySleepTimer(nil)
    }

    func performHandleShake() {
        guard AppSettings.shared.shakeExtendsSleepTimer else { return }
        if sleepTimer != nil {
            performExtendSleepTimer()
        } else if isWithinRestoreWindow, let expired = lastExpiredSleepTimer {
            applySleepTimer(SleepTimerMath.restarted(after: expired, configuration: sleepTimerConfiguration, now: .now))
            resume()
        }
    }

    var isWithinRestoreWindow: Bool {
        guard let sleepTimerExpiredAt else { return false }
        return Date.now.timeIntervalSince(sleepTimerExpiredAt) <= SleepTimerMath.restoreWindow
    }

    /// Play-to-extend: pressing play shortly after expiry restores & extends the timer.
    func restoreSleepTimerOnPlayIfNeeded() {
        guard sleepTimer == nil, AppSettings.shared.playExtendsSleepTimer, isWithinRestoreWindow, let expired = lastExpiredSleepTimer else { return }
        applySleepTimer(SleepTimerMath.restarted(after: expired, configuration: sleepTimerConfiguration, now: .now))
    }

    /// Saved timer for the item, else for its grouping (collection > series > podcast).
    func applyAutomaticSleepTimer(for item: AnyPlayableItem, origin: PlaybackOrigin) {
        guard sleepTimer == nil else { return }
        let settings = HearthData.shared.itemSettings
        var preset = settings.sleepTimer(for: item.id)
        if preset == nil {
            for grouping in PlaybackRateMath.groupingCandidates(for: item, origin: origin) {
                if let saved = settings.sleepTimer(for: grouping) {
                    preset = saved
                    break
                }
            }
        }
        if let preset {
            applySleepTimer(SleepTimerMath.state(for: preset, now: .now))
        }
    }

    // MARK: Pause awareness

    func sleepTimerPlaybackDidStart() {
        guard let sleepTimer, let pausedAt = sleepTimerPausedAt else { return }
        sleepTimerPausedAt = nil
        self.sleepTimer = SleepTimerMath.resumed(sleepTimer, pausedAt: pausedAt, now: .now)
        startSleepTimerLoop()
        sleepTimerDidChange(expired: false)
    }

    func sleepTimerPlaybackDidStop() {
        guard case .duration? = sleepTimer, sleepTimerPausedAt == nil else { return }
        sleepTimerPausedAt = .now
        refreshSleepTimerRemaining()
        sleepTimerDidChange(expired: false)
    }

    // MARK: Duration timers

    func startSleepTimerLoop() {
        sleepTimerTask?.cancel()
        sleepTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.sleepTimerTick() else { return }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func refreshSleepTimerRemaining() {
        if let sleepTimer {
            sleepTimerRemaining = SleepTimerMath.remaining(of: sleepTimer, now: .now, pausedAt: sleepTimerPausedAt)
        } else {
            sleepTimerRemaining = nil
        }
    }

    /// One tick of a duration timer; returns the delay until the next tick or `nil` to stop.
    func sleepTimerTick() -> TimeInterval? {
        guard let state = sleepTimer, let remaining = SleepTimerMath.remaining(of: state, now: .now, pausedAt: sleepTimerPausedAt) else {
            sleepTimerRemaining = nil
            return nil
        }
        sleepTimerRemaining = remaining
        guard sleepTimerPausedAt == nil else { return 1 }
        if remaining <= 0 {
            expireSleepTimer()
            return nil
        }
        if AppSettings.shared.sleepTimerFadeOut, remaining < SleepTimerMath.fadeDuration {
            setFadeVolume(SleepTimerMath.fadeVolume(timeRemaining: remaining))
            return 0.1
        }
        restoreVolumeAfterFade()
        let untilFade = remaining - SleepTimerMath.fadeDuration
        return max(0.05, min(1, untilFade > 0 ? untilFade : remaining))
    }

    // MARK: Chapter timers

    /// Called from the periodic tick: fades during the final seconds of the last chapter and pauses exactly at its end.
    func checkChapterSleepTimer() {
        guard case .chapters(let remaining, _)? = sleepTimer, remaining <= 1, isPlaying,
              let index = currentChapterIndex, chapters.indices.contains(index) else { return }
        let chapter = chapters[index]
        let timeToEnd = max(0, chapter.end - currentTime) / max(playbackRate, 0.01)
        if AppSettings.shared.sleepTimerFadeOut {
            setFadeVolume(SleepTimerMath.fadeVolume(timeRemaining: timeToEnd))
        }
        // The last chapter ends with the item → handled by the finish flow.
        let isItemEnd = chapter.end >= duration - 0.5
        guard !isItemEnd, chapterSleepTask == nil, timeToEnd <= Self.tickInterval * 1.5 else { return }
        let run = runID
        let end = chapter.end
        chapterSleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeToEnd))
            guard let self, !Task.isCancelled, self.runID == run, case .chapters? = self.sleepTimer else { return }
            self.chapterSleepTask = nil
            self.expireSleepTimer(seekTo: end)
        }
    }

    func handleSleepTimerChapterTransition(from oldIndex: Int?, to newIndex: Int?) {
        guard let sleepTimer else { return }
        switch SleepTimerMath.chapterTransition(sleepTimer, from: oldIndex, to: newIndex) {
        case .none:
            break
        case .decremented(let state):
            self.sleepTimer = state
            restoreVolumeAfterFade()
            sleepTimerDidChange(expired: false)
        case .expire:
            // Overshot the boundary: pause at the start of the new chapter.
            let start = newIndex.flatMap { chapters.indices.contains($0) ? chapters[$0].start : nil }
            expireSleepTimer(seekTo: start)
        }
    }

    func cancelPendingChapterSleep() {
        chapterSleepTask?.cancel()
        chapterSleepTask = nil
        if case .chapters? = sleepTimer {
            restoreVolumeAfterFade()
        }
    }

    // MARK: Expiry & volume

    /// Pauses (optionally at `seekTo`), clears the timer, restores volume and applies the 10 s smart rewind.
    func expireSleepTimer(pausePlayback: Bool = true, seekTo position: TimeInterval? = nil) {
        guard let expired = sleepTimer else { return }
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        chapterSleepTask?.cancel()
        chapterSleepTask = nil
        sleepTimer = nil
        sleepTimerRemaining = nil
        sleepTimerPausedAt = nil
        lastExpiredSleepTimer = expired
        sleepTimerExpiredAt = .now

        if pausePlayback, currentItem != nil {
            performPause()
            var target = position ?? currentTime
            if AppSettings.shared.smartRewind {
                let chapterStart = ChapterLookup.index(of: target, in: chapters).map { chapters[$0].start }
                target = SmartRewind.apply(SleepTimerMath.expiryRewind, to: target, chapterStart: chapterStart)
            }
            if abs(target - currentTime) > 0.01 {
                Task {
                    await seekInternal(to: target)
                }
            }
        }
        restoreVolumeAfterFade(force: true)
        sleepTimerDidChange(expired: true)
    }

    func setFadeVolume(_ volume: Float) {
        guard let player else { return }
        isFading = volume < 1
        player.volume = volume
    }

    func restoreVolumeAfterFade(force: Bool = false) {
        guard isFading || force else { return }
        isFading = false
        player?.volume = 1
    }
}
