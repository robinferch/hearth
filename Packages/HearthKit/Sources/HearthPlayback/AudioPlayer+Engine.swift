import AVFoundation
import Foundation
import HearthData
import HearthModel

/// AVQueuePlayer management: player items, multi-track seeking, periodic ticks and state observation.
extension AudioPlayer {
    static let tickInterval: TimeInterval = 0.5

    // MARK: Player

    func ensurePlayer() -> AVQueuePlayer {
        if let player {
            return player
        }
        let player = AVQueuePlayer()
        player.actionAtItemEnd = .advance
        player.automaticallyWaitsToMinimizeStalling = true
        #if os(iOS)
        // Audio only: no external video playback; AirPlay audio goes through the system route.
        player.allowsExternalPlayback = false
        #endif
        self.player = player

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: Self.tickInterval, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }

        keyValueObservations = [
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in
                    self?.syncPlayingState()
                }
            },
            player.observe(\.currentItem?.status, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in
                    self?.handleCurrentItemStatusChange()
                }
            },
        ]

        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] notification in
            guard let object = notification.object else { return }
            let identifier = ObjectIdentifier(object as AnyObject)
            MainActor.assumeIsolated {
                self?.handleTrackDidPlayToEnd(identifier)
            }
        })
        notificationTokens.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] notification in
            guard let object = notification.object else { return }
            let identifier = ObjectIdentifier(object as AnyObject)
            let message = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? any Error)?.localizedDescription
            MainActor.assumeIsolated {
                self?.handleTrackFailure(identifier, message: message)
            }
        })

        return player
    }

    func makePlayerItem(for track: AudioTrack) -> AVPlayerItem {
        let asset: AVURLAsset
        if track.url.isFileURL || streamingHeaders.isEmpty {
            asset = AVURLAsset(url: track.url)
        } else {
            asset = AVURLAsset(url: track.url, options: ["AVURLAssetHTTPHeaderFieldsKey": streamingHeaders])
        }
        let item = AVPlayerItem(asset: asset)
        // Pitch-corrected rate changes tuned for speech.
        item.audioTimePitchAlgorithm = .timeDomain
        return item
    }

    /// Replaces the player items with the tracks from `position` to the end.
    func loadTracks(from position: Int) {
        let player = ensurePlayer()
        player.removeAllItems()
        loadedTracks = []
        guard timeline.tracks.indices.contains(position) else { return }
        for index in position..<timeline.tracks.count {
            let item = makePlayerItem(for: timeline.tracks[index])
            guard player.canInsert(item, after: nil) else { continue }
            player.insert(item, after: nil)
            loadedTracks.append(LoadedTrack(item: item, position: index))
        }
    }

    func teardownPlayer() {
        guard let player else { return }
        player.pause()
        player.removeAllItems()
        player.volume = 1
        isFading = false
        loadedTracks = []
    }

    /// Track positions currently enqueued in the player, current first.
    func loadedPositions() -> [Int] {
        guard let player else { return [] }
        return player.items().compactMap { item in
            loadedTracks.first { $0.item === item }?.position
        }
    }

    func currentTrackPosition() -> Int? {
        guard let item = player?.currentItem else { return nil }
        return loadedTracks.first { $0.item === item }?.position
    }

    /// Precise seek inside the current player item.
    func seekPlayer(to local: TimeInterval) async {
        guard let player, player.currentItem != nil else { return }
        let time = CMTime(seconds: max(0, local), preferredTimescale: 1000)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                continuation.resume()
            }
        }
    }

    // MARK: Seeking

    func seekInternal(to requested: TimeInterval) async {
        guard currentItem != nil, let player, !timeline.isEmpty else { return }
        let total = duration > 0 ? duration : timeline.duration
        let target = max(0, requested)
        let plan = timeline.seekPlan(to: target, loadedPositions: loadedPositions(), totalDuration: total)
        if plan == .finish {
            await handleItemFinished()
            return
        }

        let run = runID
        busyCount += 1
        cancelPendingChapterSleep()

        // Optimistic UI update.
        currentTime = target
        updateChapterAndDisplay(fromPlayback: false)

        switch plan {
        case .finish:
            break
        case .withinCurrent(let local):
            await seekPlayer(to: local)
        case .advance(let steps, let local):
            for _ in 0..<steps {
                player.advanceToNextItem()
            }
            let remaining = player.items()
            loadedTracks.removeAll { loaded in !remaining.contains { $0 === loaded.item } }
            await seekPlayer(to: local)
        case .rebuild(let position, let local):
            loadTracks(from: position)
            await seekPlayer(to: local)
        }

        busyCount -= 1
        guard run == runID else { return }

        if intendsToPlay, player.timeControlStatus == .paused {
            player.play()
        }
        currentTime = target
        updateChapterAndDisplay(fromPlayback: false)
        syncPlayingState()
        updateNowPlayingInfo()
        if !isPlaying {
            reporter?.positionChanged(to: target)
        }
        updateSnapshot(force: !isPlaying)
    }

    /// Rebuilds player items at the current position, optionally with fresh streaming headers
    /// (token refresh, connection change, failed stream).
    func rebuildPlayerItems(refreshHeaders: Bool) async {
        guard let item = currentItem, !timeline.isEmpty else { return }
        let run = runID
        if refreshHeaders, !isPlayingLocalFiles {
            do {
                let client = try HearthData.shared.connections.client(for: item.id.connectionID)
                let headers = try await client.streamingHeaders()
                guard run == runID else { return }
                streamingHeaders = headers
            } catch {
                logger.error("Refreshing streaming headers failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard run == runID else { return }
        let time = currentTime
        let position = timeline.position(containing: time) ?? 0
        busyCount += 1
        loadTracks(from: position)
        await seekPlayer(to: timeline.localTime(for: time, at: position))
        busyCount -= 1
        guard run == runID else { return }
        if intendsToPlay {
            player?.play()
        }
        syncPlayingState()
    }

    // MARK: Ticks

    func tick() {
        guard let player, currentItem != nil, busyCount == 0, let position = currentTrackPosition() else { return }
        let local = player.currentTime().seconds
        guard local.isFinite else { return }
        let absolute = timeline.absoluteTime(local: local, at: position)
        currentTime = duration > 0 ? min(duration, absolute) : absolute
        updateChapterAndDisplay(fromPlayback: isPlaying)
        updateBuffering()
        reporter?.tick(currentTime: currentTime)
        checkChapterSleepTimer()
        updateSnapshot(force: false)
    }

    func updateChapterAndDisplay(fromPlayback: Bool) {
        let newIndex = ChapterLookup.index(of: currentTime, in: chapters)
        if newIndex != currentChapterIndex {
            let oldIndex = currentChapterIndex
            currentChapterIndex = newIndex
            chapterDidChange(from: oldIndex, to: newIndex, duringPlayback: fromPlayback)
        }
        if AppSettings.shared.chapterRelativeProgress, let chapter = currentChapter {
            displayedTime = max(0, min(currentTime - chapter.start, chapter.duration))
            displayedDuration = chapter.duration
        } else {
            displayedTime = currentTime
            displayedDuration = duration
        }
    }

    func absoluteTime(forDisplayedTime time: TimeInterval) -> TimeInterval {
        if AppSettings.shared.chapterRelativeProgress, let chapter = currentChapter {
            return chapter.start + min(max(0, time), chapter.duration)
        }
        return max(0, time)
    }

    func chapterDidChange(from oldIndex: Int?, to newIndex: Int?, duringPlayback: Bool) {
        if duringPlayback {
            handleSleepTimerChapterTransition(from: oldIndex, to: newIndex)
        }
        updateNowPlayingInfo()
        updateSnapshot(force: true)
    }

    func updateBuffering() {
        guard let player, intendsToPlay else {
            isBuffering = false
            return
        }
        let notReady = player.currentItem.map { $0.status != .readyToPlay } ?? false
        isBuffering = notReady || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }

    // MARK: Playing state

    /// Keeps `isPlaying` in line with the player's actual `timeControlStatus`.
    func syncPlayingState() {
        guard let player else { return }
        updateBuffering()
        let status = player.timeControlStatus
        let playing = status == .playing || (status == .waitingToPlayAtSpecifiedRate && player.reasonForWaitingToPlay != .noItemToPlay)

        // Ignore transient pauses while seeking / rebuilding items.
        if !playing, busyCount > 0, intendsToPlay {
            return
        }
        guard playing != isPlaying else {
            updateNowPlayingInfo()
            return
        }
        if playing {
            isPlaying = true
            intendsToPlay = true
            playbackDidStart()
        } else {
            isPlaying = false
            if intendsToPlay {
                // Paused by the system (interruption, route change, stall without recovery).
                intendsToPlay = false
                if lastPauseDate == nil {
                    lastPauseDate = .now
                }
            }
            playbackDidStop()
        }
    }

    func playbackDidStart() {
        lastPauseDate = nil
        reporter?.didStartPlaying(at: currentTime)
        sleepTimerPlaybackDidStart()
        updateNowPlayingInfo()
        updateSnapshot(force: true)
        post(Self.playbackStateChangedNotification, itemID: currentItem?.id)
    }

    func playbackDidStop() {
        reporter?.didStopPlaying(at: currentTime)
        sleepTimerPlaybackDidStop()
        updateNowPlayingInfo()
        updateSnapshot(force: true)
        post(Self.playbackStateChangedNotification, itemID: currentItem?.id)
    }

    // MARK: Track end & failures

    func handleTrackDidPlayToEnd(_ identifier: ObjectIdentifier) {
        guard let entry = loadedTracks.first(where: { ObjectIdentifier($0.item) == identifier }) else { return }
        if entry.position >= timeline.tracks.count - 1 {
            Task {
                await handleItemFinished()
            }
            return
        }
        // AVQueuePlayer advances on its own; forget the finished item.
        loadedTracks.removeAll { ObjectIdentifier($0.item) == identifier }
        if player?.items().isEmpty ?? true {
            loadTracks(from: entry.position + 1)
            if intendsToPlay {
                player?.play()
            }
        }
    }

    func handleCurrentItemStatusChange() {
        guard let item = player?.currentItem, item.status == .failed else {
            updateBuffering()
            return
        }
        handleTrackFailure(ObjectIdentifier(item), message: item.error?.localizedDescription)
    }

    func handleTrackFailure(_ identifier: ObjectIdentifier, message: String?) {
        guard loadedTracks.contains(where: { ObjectIdentifier($0.item) == identifier }) else { return }
        let reason = message ?? String(localized: "The audio stream failed.")
        logger.error("Player item failed: \(reason, privacy: .public)")
        if lastStreamRecovery.map({ Date.now.timeIntervalSince($0) > 60 }) ?? true {
            lastStreamRecovery = .now
            Task {
                await rebuildPlayerItems(refreshHeaders: true)
            }
        } else {
            lastError = .startFailed(reason)
            pause()
        }
    }
}
