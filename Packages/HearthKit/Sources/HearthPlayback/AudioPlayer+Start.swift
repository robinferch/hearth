import AVFoundation
import Foundation
import HearthAPI
import HearthData
import HearthModel

/// The start sequence (spec §1 "Start sequence").
extension AudioPlayer {
    struct ResolvedMedia {
        var tracks: [AudioTrack] = []
        var chapters: [Chapter] = []
        var session: PlaybackSessionInfo?
        var client: (any AudiobookshelfClient)?
        var headers: [String: String] = [:]
        var isLocal = false
    }

    func startPlayback(_ id: ItemIdentifier, origin: PlaybackOrigin, at explicitTime: TimeInterval?, resetUpNext: Bool) async throws {
        guard id.isPlayable else { throw PlaybackError.notPlayable }
        let data = HearthData.shared
        // 1. Downloading items can't be played (UI offers "cancel download & play").
        if data.downloads.status(of: id) == .downloading {
            throw PlaybackError.downloadInProgress
        }

        // 2. Keep running while the app is in the background (e.g. auto-advance).
        let activity = BackgroundActivity(name: "Start playback")
        defer { activity.end() }

        // A newer start supersedes this one.
        let run = UUID()
        runID = run
        busyCount += 1
        defer { busyCount -= 1 }

        let item: AnyPlayableItem
        do {
            item = try await data.items.playable(id)
        } catch {
            if runID == run {
                lastError = .startFailed(error.localizedDescription)
            }
            throw PlaybackError.startFailed(error.localizedDescription)
        }
        guard runID == run else { throw CancellationError() }

        // Stop the previous item and publish the new one (busy) right away.
        finalizeCurrentRun(finished: false)
        prepareState(for: item, origin: origin, resetUpNext: resetUpNext)

        // 3.–5. Server session / local files / fallbacks.
        let media: ResolvedMedia
        do {
            media = try await resolveMedia(for: item)
        } catch {
            if runID == run {
                let failure = (error as? PlaybackError) ?? .startFailed(error.localizedDescription)
                lastError = failure
                runID = UUID()
                resetToIdle()
                throw failure
            }
            throw error
        }
        guard runID == run else {
            Self.closeAbandonedSession(media)
            throw CancellationError()
        }

        let timeline = PlaybackTimeline(tracks: media.tracks)
        let total = timeline.duration > 0 ? timeline.duration : (media.session.map(\.duration).flatMap { $0 > 0 ? $0 : nil } ?? item.duration)

        // 6. Episode chapters from the show notes when the server has none.
        var chapters = media.chapters
        if chapters.isEmpty, case .episode(let episode) = item {
            chapters = DescriptionChapterParser.chapters(from: episode.descriptionHTML, duration: total)
        }
        // 7. Sort / normalize; lock the download.
        chapters = ChapterLookup.normalized(chapters, duration: total)

        let start = resolveStartTime(for: id, explicitTime: explicitTime, session: media.session, duration: total, chapters: chapters)

        self.timeline = timeline
        streamingHeaders = media.headers
        isPlayingLocalFiles = media.isLocal
        duration = total
        self.chapters = chapters
        lastStreamRecovery = nil
        data.downloads.lock(id)
        reporter = SessionReporter(itemID: id, sessionID: media.session?.id, client: media.client, startTime: start, duration: total)

        // 8. Load tracks, seek to start, publish.
        let position = timeline.position(containing: start) ?? 0
        loadTracks(from: position)
        await seekPlayer(to: timeline.localTime(for: start, at: position))
        guard runID == run else { throw CancellationError() }
        currentTime = start
        updateChapterAndDisplay(fromPlayback: false)

        // 9. Rate: item → grouping → default.
        applyPlaybackRate(resolvePlaybackRate(for: item, origin: origin), save: false)

        // 10. Play, remember, notify.
        lastError = nil
        lastPauseDate = nil
        startedItemAt = .now
        lastPlayedItemID = id
        PlaybackPersistence.lastPlayedItemID = id
        PlaybackPersistence.lastPlayedOrigin = origin

        await activateAndPlay()
        guard runID == run else { throw CancellationError() }

        updateNowPlayingInfo()
        updateRemoteCommandAvailability()
        loadArtwork(for: item)
        applyAutomaticSleepTimer(for: item, origin: origin)
        updateSnapshot(force: true)
        loadSnapshotCover(for: id)
        post(Self.itemStartedNotification, itemID: id)

        Task {
            await generateUpNextIfNeeded()
        }
    }

    /// Publishes the new item before its media is resolved (UI shows it as busy).
    func prepareState(for item: AnyPlayableItem, origin: PlaybackOrigin, resetUpNext: Bool) {
        currentItem = item
        self.origin = origin
        chapters = []
        currentChapterIndex = nil
        currentTime = 0
        duration = item.duration
        displayedTime = 0
        displayedDuration = item.duration
        isBuffering = false
        isPlayingLocalFiles = false
        timeline = .empty
        snapshotCoverFile = nil
        finishingRunID = nil

        queue.removeAll { $0.id == item.id }
        if resetUpNext {
            upNext = []
            upNextSource = nil
            upNextGenerationDisabled = false
        } else {
            upNext.removeAll { $0.id == item.id }
        }
        queueDidChange()
    }

    func resolveMedia(for item: AnyPlayableItem) async throws -> ResolvedMedia {
        let data = HearthData.shared
        let id = item.id
        var media = ResolvedMedia()
        let local = data.downloads.localPlayback(for: id)
        let client = try? data.connections.client(for: id.connectionID)
        let online = client != nil && !data.connections.isOffline
        media.client = client

        if online, let client {
            do {
                media.session = try await client.startSession(id, device: data.listening.deviceInfo)
            } catch {
                logger.warning("Starting a server session failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        do {
            if let local, !local.tracks.isEmpty {
                // Downloaded: local files & stored chapters replace server ones.
                media.tracks = local.tracks
                media.isLocal = true
                media.chapters = local.chapters.isEmpty ? (media.session?.chapters ?? []) : local.chapters
            } else if let session = media.session, !session.tracks.isEmpty, let client {
                media.tracks = session.tracks
                media.chapters = session.chapters
                media.headers = try await client.streamingHeaders()
            } else if online, let client {
                // No session: stream the files directly.
                let details = try await data.items.playableDetails(id)
                var tracks: [AudioTrack] = []
                var headers: [String: String] = [:]
                for (index, file) in details.audioFiles.sorted(by: { $0.offset < $1.offset }).enumerated() {
                    let request = try await client.audioFileRequest(for: id, ino: file.ino)
                    guard let url = request.url else { continue }
                    tracks.append(AudioTrack(index: index, offset: file.offset, duration: file.duration, url: url, mimeType: file.mimeType))
                    headers.merge(request.allHTTPHeaderFields ?? [:]) { _, new in new }
                }
                media.tracks = tracks
                media.chapters = details.chapters
                media.headers = headers
            }
        } catch {
            Self.closeAbandonedSession(media)
            throw PlaybackError.startFailed(error.localizedDescription)
        }

        guard !media.tracks.isEmpty else {
            Self.closeAbandonedSession(media)
            if online {
                throw PlaybackError.startFailed(String(localized: "No audio files were found for this item."))
            }
            throw PlaybackError.startFailed(String(localized: "This item isn't downloaded and the server can't be reached."))
        }
        return media
    }

    /// Start position: explicit time > server session / local progress, with cold-start smart rewind.
    func resolveStartTime(for id: ItemIdentifier, explicitTime: TimeInterval?, session: PlaybackSessionInfo?, duration: TimeInterval, chapters: [Chapter]) -> TimeInterval {
        if let explicitTime {
            return min(max(0, explicitTime), max(0, duration - 1))
        }
        let progress = HearthData.shared.progress.progress(for: id)
        if progress?.isFinished == true {
            return 0
        }
        var start: TimeInterval = 0
        if let session, session.startTime > 0 {
            start = session.startTime
        } else if let progress {
            start = progress.currentTime
        }
        // A position at the very end restarts the item.
        if duration > 0, start >= duration - 1 {
            return 0
        }
        if AppSettings.shared.smartRewind, start > 0 {
            let rewind = SmartRewind.coldStartRewind(lastUpdate: progress?.lastUpdate, now: .now)
            start = SmartRewind.apply(rewind, to: start, chapterStart: nil)
        }
        return max(0, start)
    }

    func resolvePlaybackRate(for item: AnyPlayableItem, origin: PlaybackOrigin) -> Double {
        let settings = HearthData.shared.itemSettings
        if let rate = settings.playbackRate(for: item.id) {
            return rate
        }
        for grouping in PlaybackRateMath.groupingCandidates(for: item, origin: origin) {
            if let rate = settings.playbackRate(for: grouping) {
                return rate
            }
        }
        return AppSettings.shared.defaultPlaybackRate
    }

    /// Closes a server session opened by a start that was superseded or failed.
    static func closeAbandonedSession(_ media: ResolvedMedia) {
        guard let session = media.session, let client = media.client else { return }
        Task {
            try? await client.closeSession(session.id, currentTime: session.startTime, duration: session.duration, timeListened: 0)
        }
    }

    // MARK: Finalize / idle

    /// Forced report + session close for the current item, tears down the player items and unlocks the download.
    func finalizeCurrentRun(finished: Bool, afterReport: (@MainActor () async -> Void)? = nil) {
        guard let item = currentItem else { return }
        let time = finished ? duration : currentTime
        if let reporter {
            reporter.finalize(currentTime: time, finished: finished, then: afterReport)
        } else if let afterReport {
            Task {
                await afterReport()
            }
        }
        reporter = nil
        intendsToPlay = false
        cancelPendingChapterSleep()
        teardownPlayer()
        HearthData.shared.downloads.unlock(item.id)
        isPlaying = false
        isBuffering = false
    }

    /// Clears all per-item state (nothing loaded).
    func resetToIdle() {
        let wasActive = currentItem != nil
        currentItem = nil
        origin = .none
        chapters = []
        currentChapterIndex = nil
        currentTime = 0
        duration = 0
        displayedTime = 0
        displayedDuration = 0
        isPlaying = false
        isBuffering = false
        isPlayingLocalFiles = false
        intendsToPlay = false
        timeline = .empty
        streamingHeaders = [:]
        upNext = []
        upNextSource = nil
        artworkTask?.cancel()
        artworkItemID = nil
        nowPlayingArtwork = nil
        clearNowPlayingInfo()
        updateRemoteCommandAvailability()
        deactivateAudioSession()
        updateSnapshot(force: true)
        if wasActive {
            post(Self.playbackStateChangedNotification)
        }
    }

    func activateAndPlay() async {
        guard player != nil else { return }
        intendsToPlay = true
        let run = runID
        guard await activateAudioSession() else {
            intendsToPlay = false
            return
        }
        guard run == runID, intendsToPlay, let player else { return }
        if !isFading {
            player.volume = 1
        }
        player.defaultRate = Float(playbackRate)
        player.play()
        syncPlayingState()
    }
}
