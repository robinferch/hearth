import Foundation
import HearthData
import HearthModel
import Observation

#if os(iOS)
import UIKit
#elseif os(watchOS)
import WatchKit
#endif

/// Setup, app lifecycle, settings observation and the widget snapshot.
extension AudioPlayer {
    func performSetup() {
        guard !didSetup else { return }
        didSetup = true
        lastPlayedItemID = PlaybackPersistence.lastPlayedItemID
        configureAudioSession()
        configureRemoteCommands()
        updateRemoteCommandAvailability()
        observeLifecycle()
        observeSettings()
        restoreQueue()
    }

    func observeLifecycle() {
        let center = NotificationCenter.default
        #if os(iOS)
        let background: Notification.Name? = UIApplication.didEnterBackgroundNotification
        let terminate: Notification.Name? = UIApplication.willTerminateNotification
        #elseif os(watchOS)
        let background: Notification.Name? = WKApplication.didEnterBackgroundNotification
        let terminate: Notification.Name? = nil
        #else
        let background: Notification.Name? = nil
        let terminate: Notification.Name? = nil
        #endif

        if let background {
            notificationTokens.append(center.addObserver(forName: background, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.appDidEnterBackground()
                }
            })
        }
        if let terminate {
            notificationTokens.append(center.addObserver(forName: terminate, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.appWillTerminate()
                }
            })
        }
    }

    /// Re-applies settings that affect remote commands and displayed times whenever they change.
    func observeSettings() {
        withObservationTracking {
            let settings = AppSettings.shared
            _ = settings.skipForwardInterval
            _ = settings.skipBackwardInterval
            _ = settings.lockSeekBar
            _ = settings.chapterRelativeProgress
            _ = settings.playbackRatePresets
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.updateRemoteCommandAvailability()
                if self.currentItem != nil {
                    self.updateChapterAndDisplay(fromPlayback: false)
                    self.updateNowPlayingInfo()
                }
                self.observeSettings()
            }
        }
    }

    // MARK: Snapshot

    static let snapshotInterval: TimeInterval = 30

    /// Keeps the shared snapshot (widgets, controls, Live Activity, watch) in sync. Throttled unless forced.
    func updateSnapshot(force: Bool) {
        let now = Date.now
        guard force || now.timeIntervalSince(lastSnapshotUpdate) >= Self.snapshotInterval else { return }
        lastSnapshotUpdate = now

        let entry: SharedSnapshot.Entry? = currentItem.map { item in
            let subtitle: String? = switch item {
            case .audiobook(let audiobook): audiobook.authorLine
            case .episode(let episode): episode.podcastName
            }
            return SharedSnapshot.Entry(
                id: item.id,
                title: item.name,
                subtitle: subtitle,
                progress: duration > 0 ? min(1, max(0, currentTime / duration)) : 0,
                remaining: duration > 0 ? max(0, duration - currentTime) : nil,
                isDownloaded: isPlayingLocalFiles || HearthData.shared.downloads.status(of: item.id) == .completed,
                coverFile: snapshotCoverFile
            )
        }
        let clearNowPlaying = currentItem == nil && lastPlayedItemID == nil
        let isPlaying = isPlaying || (intendsToPlay && currentItem != nil)
        let chapterTitle = currentChapter?.title
        let sleepTimer = sleepTimer

        HearthData.shared.snapshot.update { snapshot in
            if let entry {
                snapshot.nowPlaying = entry
            } else if clearNowPlaying {
                snapshot.nowPlaying = nil
            }
            snapshot.isPlaying = isPlaying
            snapshot.chapterTitle = entry == nil ? nil : chapterTitle
            snapshot.sleepTimer = sleepTimer
            snapshot.updatedAt = now
        }
    }

    func loadSnapshotCover(for id: ItemIdentifier) {
        Task { [weak self] in
            let file = await HearthData.shared.snapshot.storeCover(for: id)
            guard let self, self.currentItem?.id == id, let file else { return }
            self.snapshotCoverFile = file
            self.updateSnapshot(force: true)
        }
    }
}

/// Keeps the app alive in the background while starting playback / reporting (iOS only).
@MainActor
final class BackgroundActivity {
    #if os(iOS)
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    #endif

    init(name: String) {
        #if os(iOS)
        guard !Self.isAppExtension else { return }
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                self?.end()
            }
        }
        #endif
    }

    private static let isAppExtension = Bundle.main.bundleURL.pathExtension == "appex"

    func end() {
        #if os(iOS)
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
        #endif
    }
}
