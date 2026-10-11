import Foundation
import HearthData
import HearthModel

#if os(iOS) || os(watchOS)
import MediaPlayer
import UIKit

/// Remote command center & Now Playing info (spec §1).
extension AudioPlayer {
    func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            self?.resume()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        center.stopCommand.addTarget { [weak self] _ in
            Task { await self?.stop() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, !AppSettings.shared.lockSeekBar, let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = event.positionTime
            Task { await self.seek(toDisplayedTime: position) }
            return .success
        }
        center.skipForwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval
            Task { await self?.skipForward(interval.flatMap { $0 > 0 ? $0 : nil }) }
            return .success
        }
        center.skipBackwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval
            Task { await self?.skipBackward(interval.flatMap { $0 > 0 ? $0 : nil }) }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, self.currentItem != nil else { return .noActionableNowPlayingItem }
            Task {
                if AppSettings.shared.remoteNextPreviousSkipsChapters {
                    await self.nextChapter()
                } else {
                    await self.skipForward()
                }
            }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, self.currentItem != nil else { return .noActionableNowPlayingItem }
            Task {
                if AppSettings.shared.remoteNextPreviousSkipsChapters {
                    await self.previousChapter()
                } else {
                    await self.skipBackward()
                }
            }
            return .success
        }
        // Seek forward/backward (long press on some remotes): skip once on begin, ignore end.
        center.seekForwardCommand.addTarget { [weak self] event in
            guard (event as? MPSeekCommandEvent)?.type == .beginSeeking else { return .success }
            Task { await self?.skipForward() }
            return .success
        }
        center.seekBackwardCommand.addTarget { [weak self] event in
            guard (event as? MPSeekCommandEvent)?.type == .beginSeeking else { return .success }
            Task { await self?.skipBackward() }
            return .success
        }
        center.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let rate = (event as? MPChangePlaybackRateCommandEvent)?.playbackRate else { return .commandFailed }
            self?.setPlaybackRate(Double(rate))
            return .success
        }
        center.bookmarkCommand.localizedTitle = String(localized: "Add Bookmark", bundle: .module)
        center.bookmarkCommand.localizedShortTitle = String(localized: "Bookmark", bundle: .module)
        center.bookmarkCommand.addTarget { [weak self] _ in
            guard let self, self.canCreateBookmark else { return .commandFailed }
            Task {
                do {
                    try await self.createBookmark()
                } catch {
                    self.logger.error("Remote bookmark failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            return .success
        }

        center.likeCommand.isEnabled = false
        center.dislikeCommand.isEnabled = false
        center.ratingCommand.isEnabled = false
        center.changeRepeatModeCommand.isEnabled = false
        center.changeShuffleModeCommand.isEnabled = false
        #if os(iOS)
        center.enableLanguageOptionCommand.isEnabled = false
        center.disableLanguageOptionCommand.isEnabled = false
        #endif
    }

    /// Live-updates intervals, rates and enabled state.
    func updateRemoteCommandAvailability() {
        let center = MPRemoteCommandCenter.shared()
        let settings = AppSettings.shared
        let active = currentItem != nil

        center.skipForwardCommand.preferredIntervals = [NSNumber(value: settings.skipForwardInterval)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: settings.skipBackwardInterval)]
        center.skipForwardCommand.isEnabled = active
        center.skipBackwardCommand.isEnabled = active
        center.seekForwardCommand.isEnabled = active
        center.seekBackwardCommand.isEnabled = active
        center.nextTrackCommand.isEnabled = active
        center.previousTrackCommand.isEnabled = active
        center.changePlaybackPositionCommand.isEnabled = active && !settings.lockSeekBar
        center.changePlaybackRateCommand.supportedPlaybackRates = settings.playbackRatePresets.sorted().map { NSNumber(value: $0) }
        center.changePlaybackRateCommand.isEnabled = active
        center.bookmarkCommand.isEnabled = canCreateBookmark
        center.stopCommand.isEnabled = active
    }

    func updateNowPlayingInfo() {
        guard let item = currentItem else { return }
        var info: [String: Any] = [:]
        let chapter = currentChapter

        info[MPMediaItemPropertyTitle] = chapter?.title ?? item.name
        switch item {
        case .audiobook(let audiobook):
            info[MPMediaItemPropertyAlbumTitle] = audiobook.name
        case .episode(let episode):
            info[MPMediaItemPropertyAlbumTitle] = episode.podcastName
        }
        info[MPMediaItemPropertyArtist] = item.base.authorLine ?? ""
        info[MPNowPlayingInfoPropertyExternalContentIdentifier] = item.id.description
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyIsLiveStream] = false

        info[MPMediaItemPropertyPlaybackDuration] = displayedDuration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = displayedTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying && !isBuffering ? playbackRate : 0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = playbackRate
        if duration > 0 {
            info[MPNowPlayingInfoPropertyPlaybackProgress] = Float(min(1, currentTime / duration))
        }

        if !chapters.isEmpty {
            info[MPNowPlayingInfoPropertyChapterCount] = chapters.count
            if let currentChapterIndex {
                info[MPNowPlayingInfoPropertyChapterNumber] = currentChapterIndex
            }
        }
        info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = 0
        info[MPNowPlayingInfoPropertyPlaybackQueueCount] = 1 + queue.count + upNext.count

        if artworkItemID == item.id, let artwork = nowPlayingArtwork as? MPMediaItemArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        #if os(iOS)
        center.playbackState = isPlaying ? (isBuffering ? .interrupted : .playing) : .paused
        #endif
    }

    func clearNowPlayingInfo() {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        #if os(iOS)
        center.playbackState = .stopped
        #endif
    }

    func loadArtwork(for item: AnyPlayableItem) {
        guard artworkItemID != item.id || nowPlayingArtwork == nil else { return }
        artworkTask?.cancel()
        artworkItemID = item.id
        nowPlayingArtwork = nil
        let id = item.id
        artworkTask = Task { [weak self] in
            guard let data = await HearthData.shared.images.imageData(for: id, size: .large),
                  let image = UIImage(data: data) else { return }
            guard let self, !Task.isCancelled, self.artworkItemID == id else { return }
            self.nowPlayingArtwork = Self.makeArtwork(image)
            self.updateNowPlayingInfo()
        }
    }

    /// Built outside the main actor: MediaPlayer calls the request handler on arbitrary threads.
    nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}

#else

extension AudioPlayer {
    func configureRemoteCommands() {}
    func updateRemoteCommandAvailability() {}
    func updateNowPlayingInfo() {}
    func clearNowPlayingInfo() {}
    func loadArtwork(for item: AnyPlayableItem) {}
}

#endif
