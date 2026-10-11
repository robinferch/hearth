import AVFoundation
import Foundation
import HearthData
import HearthModel

/// AVQueuePlayer management: player items, multi-track seeking, periodic ticks and state observation.
extension AudioPlayer {
    static let tickInterval: TimeInterval = 0.5
    /// How long the player may wait for data before listening time and the sleep timer stop counting.
    static let stallGracePeriod: TimeInterval = 3

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
        player.defaultRate = Float(playbackRate)
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
        playerNotificationTokens.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] notification in
            guard let object = notification.object else { return }
            let identifier = ObjectIdentifier(object as AnyObject)
            MainActor.assumeIsolated {
                self?.handleTrackDidPlayToEnd(identifier)
            }
        })
        playerNotificationTokens.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] notification in
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
        itemStatusObservations = []
        guard timeline.tracks.indices.contains(position) else { return }
        for index in position..<timeline.tracks.count {
            let item = makePlayerItem(for: timeline.tracks[index])
            guard player.canInsert(item, after: nil) else { continue }
            player.insert(item, after: nil)
            loadedTracks.append(LoadedTrack(item: item, position: index))
            itemStatusObservations.append(observeFailure(of: item))
        }
    }

    /// `AVQueuePlayer` drops an item that fails to load (e.g. HTTP 401) from its queue without a failure
    /// notification and before it becomes `currentItem`: watch every item's status.
    private func observeFailure(of item: AVPlayerItem) -> NSKeyValueObservation {
        item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let identifier = ObjectIdentifier(item)
            let message = item.error?.localizedDescription
            Task { @MainActor in
                self?.handleTrackFailure(identifier, message: message)
            }
        }
    }

    func teardownPlayer() {
        guard let player else { return }
        player.pause()
        player.removeAllItems()
        player.volume = 1
        isFading = false
        loadedTracks = []
        itemStatusObservations = []
    }

    /// Releases the player and all its observers (it is recreated on demand, e.g. after a media services reset).
    func destroyPlayer() {
        teardownPlayer()
        if let player, let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        keyValueObservations.forEach { $0.invalidate() }
        keyValueObservations = []
        let center = NotificationCenter.default
        playerNotificationTokens.forEach { center.removeObserver($0) }
        playerNotificationTokens = []
        stopStallTracking()
        player = nil
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
        post(Self.positionChangedNotification, itemID: currentItem?.id)
    }

    /// Rebuilds player items at the current position, optionally with fresh streaming headers
    /// (token refresh, connection change, failed stream, media services reset).
    /// - Parameter resume: Play afterwards even if the player was paused in the meantime (by the failure itself).
    ///   A pause by the user during the rebuild still wins.
    func rebuildPlayerItems(refreshHeaders: Bool, resume: Bool = false) async {
        guard currentItem != nil, !timeline.isEmpty else { return }
        let run = runID
        if resume {
            intendsToPlay = true
            systemPausedAt = nil
        }
        // Busy for the whole rebuild: pauses it causes are neither user nor system pauses.
        busyCount += 1
        let reloaded = await reloadPlayerItems(refreshHeaders: refreshHeaders, run: run)
        busyCount -= 1
        guard reloaded, run == runID else { return }
        if intendsToPlay {
            player?.play()
        }
        syncPlayingState()
    }

    private func reloadPlayerItems(refreshHeaders: Bool, run: UUID) async -> Bool {
        guard let item = currentItem else { return false }
        if refreshHeaders, !isPlayingLocalFiles {
            do {
                let client = try HearthData.shared.connections.client(for: item.id.connectionID)
                let headers = try await client.streamingHeaders()
                guard run == runID else { return false }
                streamingHeaders = headers
            } catch {
                logger.error("Refreshing streaming headers failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard run == runID, !timeline.isEmpty else { return false }
        let time = currentTime
        let position = timeline.position(containing: time) ?? 0
        loadTracks(from: position)
        await seekPlayer(to: timeline.localTime(for: time, at: position))
        return run == runID
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
        let waiting = status == .waitingToPlayAtSpecifiedRate && player.reasonForWaitingToPlay != .noItemToPlay
        let playing = status == .playing || waiting

        // Ignore transient pauses while seeking / rebuilding items.
        if !playing, busyCount > 0, intendsToPlay {
            return
        }
        if playing == isPlaying {
            updateNowPlayingInfo()
        } else if playing {
            isPlaying = true
            intendsToPlay = true
            playbackDidStart()
        } else {
            isPlaying = false
            if intendsToPlay {
                // Paused by the system (interruption, route change, stall without recovery).
                intendsToPlay = false
                systemPausedAt = .now
                if lastPauseDate == nil {
                    lastPauseDate = .now
                }
            }
            playbackDidStop()
        }
        updateStallTracking(waiting: isPlaying && waiting)
    }

    // MARK: Listening clock & stalls

    /// Listening time (session reporter) and duration sleep timers count while audio actually plays.
    func startListeningClock() {
        guard !isListeningClockRunning else { return }
        isListeningClockRunning = true
        reporter?.didStartPlaying(at: currentTime)
        sleepTimerPlaybackDidStart()
    }

    func stopListeningClock() {
        guard isListeningClockRunning else { return }
        isListeningClockRunning = false
        reporter?.didStopPlaying(at: currentTime)
        sleepTimerPlaybackDidStop()
    }

    /// A network stall keeps `isPlaying` (the player resumes on its own) but stops the clock after a grace period.
    func updateStallTracking(waiting: Bool) {
        guard waiting else {
            stopStallTracking()
            if isPlaying {
                startListeningClock()
            }
            return
        }
        guard stallTask == nil, isListeningClockRunning else { return }
        let run = runID
        stallTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.stallGracePeriod))
            guard let self, !Task.isCancelled, self.runID == run else { return }
            self.stallTask = nil
            guard self.isPlaying, self.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
            self.logger.notice("Playback stalled; listening time and the sleep timer are paused")
            self.stopListeningClock()
        }
    }

    func stopStallTracking() {
        stallTask?.cancel()
        stallTask = nil
    }

    func playbackDidStart() {
        lastPauseDate = nil
        systemPausedAt = nil
        startListeningClock()
        updateNowPlayingInfo()
        updateSnapshot(force: true)
        post(Self.playbackStateChangedNotification, itemID: currentItem?.id)
    }

    func playbackDidStop() {
        stopStallTracking()
        stopListeningClock()
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

    /// A player item failed. Streams rejected with 401/403 (expired token) refresh the authorization and continue;
    /// other failures rebuild once a minute, then give up. A failure is reported twice (notification + status),
    /// so failures during a recovery are ignored.
    func handleTrackFailure(_ identifier: ObjectIdentifier, message: String?) {
        guard let failed = loadedTracks.first(where: { ObjectIdentifier($0.item) == identifier }), !isRecoveringStream else { return }
        let reason = message ?? String(localized: "The audio stream failed.")
        let errorEvent = failed.item.errorLog()?.events.last
        logger.error("Player item failed: \(reason, privacy: .public) (\(errorEvent?.errorStatusCode ?? 0), \(errorEvent?.errorComment ?? "-", privacy: .public))")

        let now = Date.now
        let isAuthFailure = !isPlayingLocalFiles && StreamingAuth.isAuthorizationFailure(
            statusCode: errorEvent?.errorStatusCode,
            error: failed.item.error,
            texts: [message, errorEvent?.errorComment]
        )
        let mayRecoverAuth = isAuthFailure && (lastAuthRecovery.map { now.timeIntervalSince($0) > StreamingAuth.recoveryInterval } ?? true)
        let mayRecover = lastStreamRecovery.map { now.timeIntervalSince($0) > 60 } ?? true
        guard mayRecoverAuth || mayRecover else {
            lastError = .startFailed(reason)
            pause()
            return
        }
        if mayRecoverAuth {
            lastAuthRecovery = now
        } else {
            lastStreamRecovery = now
        }
        // The failure pauses the player (possibly reported before this notification): remember whether it played.
        let wasPlaying = InterruptionLogic.wasPlaying(isPlaying: isPlaying, intendsToPlay: intendsToPlay, systemPausedAt: systemPausedAt, now: now)
        // Busy right away so the pause isn't taken for a system pause before the rebuild starts.
        busyCount += 1
        isRecoveringStream = true
        Task {
            if mayRecoverAuth {
                await refreshStreamingAuthorization()
            }
            await rebuildPlayerItems(refreshHeaders: true, resume: wasPlaying)
            isRecoveringStream = false
            busyCount -= 1
        }
    }

    /// Forces a token refresh for the rejected streaming headers (no-op when the token changed meanwhile).
    func refreshStreamingAuthorization() async {
        guard let item = currentItem, let url = timeline.tracks.first?.url else { return }
        logger.notice("Stream authorization was rejected; refreshing the access token")
        var rejected = URLRequest(url: url)
        rejected.allHTTPHeaderFields = streamingHeaders
        do {
            let client = try HearthData.shared.connections.client(for: item.id.connectionID)
            try await client.refreshAuthorization(rejectedRequest: rejected)
        } catch {
            // The rebuild still fetches the current headers; another rejection ends in the regular failure path.
            logger.error("Refreshing the stream authorization failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
