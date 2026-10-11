import Foundation
import HearthData
import HearthModel
import HearthPlayback
import Observation
import OSLog

/// iPhone side of the Apple Watch connection.
///
/// - Answers credential requests (connections + tokens) so the watch can sign in without typing.
/// - Keeps tokens in sync in both directions (audiobookshelf rotates refresh tokens).
/// - Pushes the player state to the watch (live message when reachable, application context otherwise) and
///   executes remote commands on `AudioPlayer.shared`.
/// - Mirrors the widget snapshot into the application context for the watch complications.
@MainActor
final class WatchBridge {
    static let shared = WatchBridge()

    private let session = WatchSyncSession.shared
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hearth", category: "WatchBridge")

    private var didActivate = false
    private var pushTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var tokenTask: Task<Void, Never>?
    private var notificationTokens: [any NSObjectProtocol] = []
    private var lastContext: WatchPhoneContext?
    private var lastComplicationKey: String?
    private var knownConnectionIDs = Set<ConnectionID>()

    private init() {}

    /// Starts WatchConnectivity and the observers. Call once at launch.
    func activate() {
        guard !didActivate, session.isSupported else { return }
        didActivate = true
        session.messageHandler = { [weak self] message in
            await self?.handle(message)
        }
        session.stateHandler = { [weak self] in
            self?.sessionStateChanged()
        }
        session.activate()
        observePlayer()
        observeSnapshot()
        observeConnections()
        observeNotifications()
        startTokenMonitoring()
    }

    // MARK: Incoming

    private func handle(_ message: WatchSyncMessage) async -> WatchSyncMessage? {
        switch message {
        case .credentialsRequest:
            // Connections are loaded when the store is created; no need to wait for the bootstrap.
            let credentials = HearthData.shared.connections.watchCredentials()
            logger.info("Sending \(credentials.entries.count) connection(s) to the watch")
            return .credentials(credentials)
        case .credentials(let credentials):
            // The watch refreshed tokens (or answered our request after we became unauthorized).
            await HearthData.shared.connections.applyWatchCredentials(credentials)
            return .acknowledged
        case .nowPlayingRequest:
            return .nowPlayingState(Self.makeState())
        case .command(let command):
            let failure = await perform(command)
            return .commandResult(WatchCommandResult(failure: failure, state: Self.makeState()))
        case .nowPlayingState, .commandResult, .context, .acknowledged:
            return nil
        }
    }

    private func sessionStateChanged() {
        guard session.activation == .activated else { return }
        pushContext(force: true)
    }

    // MARK: Commands

    private func perform(_ command: WatchCommand) async -> WatchCommandFailure? {
        let player = AudioPlayer.shared
        let needsItem: Bool = switch command {
        case .playItem, .resumeLastPlayed, .play, .togglePlayPause: false
        default: true
        }
        if needsItem, !player.isActive {
            return .nothingPlaying
        }

        switch command {
        case .play:
            player.resume()
        case .pause:
            player.pause()
        case .togglePlayPause:
            if player.isActive {
                player.togglePlayPause()
            } else {
                return await resumeLastPlayed()
            }
        case .skipForward(let seconds):
            await player.skipForward(seconds)
        case .skipBackward(let seconds):
            await player.skipBackward(seconds)
        case .nextChapter:
            await player.nextChapter()
        case .previousChapter:
            await player.previousChapter()
        case .seekToChapter(let id):
            guard let chapter = player.chapters.first(where: { $0.id == id }) else { return .failed }
            await player.seek(toChapter: chapter)
        case .seekToDisplayedTime(let time):
            await player.seek(toDisplayedTime: time)
        case .setPlaybackRate(let rate):
            player.setPlaybackRate(min(4, max(0.25, rate)))
        case .cyclePlaybackRate:
            player.cyclePlaybackRate()
        case .setSleepTimer(let preset):
            player.setSleepTimer(preset)
        case .sleepAtEndOfChapter(let id):
            guard let chapter = player.chapters.first(where: { $0.id == id }) else { return .failed }
            player.setSleepTimer(endOf: chapter)
        case .extendSleepTimer:
            player.extendSleepTimer()
        case .adjustSleepTimer(let delta):
            player.adjustSleepTimer(by: delta)
        case .cancelSleepTimer:
            player.cancelSleepTimer()
        case .createBookmark(let note):
            guard player.canCreateBookmark else { return .bookmarkUnsupported }
            do {
                try await player.createBookmark(note: note)
            } catch {
                logger.error("Creating a bookmark from the watch failed: \(error.localizedDescription, privacy: .public)")
                return .failed
            }
        case .playItem(let id, let time):
            do {
                if player.isCurrent(id), time == nil {
                    player.resume()
                } else {
                    try await player.play(id, at: time)
                }
            } catch {
                return Self.failure(for: error)
            }
        case .resumeLastPlayed:
            return await resumeLastPlayed()
        case .stop:
            await player.stop()
        }
        return nil
    }

    private func resumeLastPlayed() async -> WatchCommandFailure? {
        do {
            try await AudioPlayer.shared.resumeLastPlayed()
            return nil
        } catch {
            return Self.failure(for: error)
        }
    }

    private static func failure(for error: any Error) -> WatchCommandFailure {
        switch error as? PlaybackError {
        case .notPlayable: .notPlayable
        case .downloadInProgress: .downloadInProgress
        case .noPlaybackItem: .nothingPlaying
        case .startFailed: .itemUnavailable
        case nil: .failed
        }
    }

    // MARK: Player state

    static func makeState() -> WatchNowPlayingState? {
        let player = AudioPlayer.shared
        guard let item = player.currentItem else { return nil }
        let settings = AppSettings.shared
        let subtitle: String? = switch item {
        case .audiobook(let audiobook): audiobook.authorLine
        case .episode(let episode): episode.podcastName
        }
        return WatchNowPlayingState(
            itemID: item.id,
            title: item.name,
            subtitle: subtitle,
            chapterTitle: player.currentChapter?.title,
            chapterIndex: player.currentChapterIndex,
            chapters: player.chapters,
            isPlaying: player.isPlaying,
            isBuffering: player.isBuffering,
            currentTime: player.currentTime,
            duration: player.duration,
            displayedTime: player.displayedTime,
            displayedDuration: player.displayedDuration,
            playbackRate: player.playbackRate,
            sleepTimer: player.sleepTimer,
            sleepTimerRemaining: player.sleepTimerRemaining,
            canCreateBookmark: player.canCreateBookmark,
            routeName: player.route.name,
            routeSymbol: player.route.systemImage,
            skipBackwardInterval: settings.skipBackwardInterval,
            skipForwardInterval: settings.skipForwardInterval,
            playbackRatePresets: settings.playbackRatePresets
        )
    }

    /// Re-arms itself; any change of the observed properties schedules a (debounced) push.
    private func observePlayer() {
        withObservationTracking {
            let player = AudioPlayer.shared
            _ = player.currentItem?.id
            _ = player.isPlaying
            _ = player.isBuffering
            _ = player.currentChapterIndex
            _ = player.chapters.count
            _ = player.playbackRate
            _ = player.sleepTimer
            _ = player.route
            _ = player.duration
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.schedulePush()
                self?.observePlayer()
            }
        }
    }

    private func observeNotifications() {
        let center = NotificationCenter.default
        let names = [
            AudioPlayer.itemStartedNotification,
            AudioPlayer.itemFinishedNotification,
            AudioPlayer.sleepTimerChangedNotification,
            AudioPlayer.playbackStateChangedNotification,
        ]
        for name in names {
            notificationTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.schedulePush()
                }
            })
        }
    }

    private func schedulePush() {
        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            pushState()
        }
        updateHeartbeat()
    }

    /// While playing, the watch extrapolates the position; a periodic push corrects drift and sleep timer ticks.
    private func updateHeartbeat() {
        let playing = AudioPlayer.shared.isPlaying
        if playing, heartbeatTask == nil {
            heartbeatTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled else { return }
                    session.sendIfReachable(.nowPlayingState(Self.makeState()))
                }
            }
        } else if !playing {
            heartbeatTask?.cancel()
            heartbeatTask = nil
        }
    }

    private func pushState() {
        guard session.activation == .activated else { return }
        let state = Self.makeState()
        session.sendIfReachable(.nowPlayingState(state))
        pushContext(force: false)
        pushComplicationIfNeeded(state)
    }

    // MARK: Context & complications

    private func observeSnapshot() {
        // The snapshot store isn't observable; Listen Now / listened today changes are picked up with the next
        // player change, the heartbeat, and this slow timer.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                self?.pushContext(force: false)
            }
        }
    }

    private func pushContext(force: Bool) {
        guard session.activation == .activated else { return }
        guard session.isWatchAppInstalled else { return }
        var state = Self.makeState()
        var snapshot = HearthData.shared.snapshot.snapshot
        // Cover file names refer to this device's container; the watch stores its own covers.
        snapshot.nowPlaying?.coverFile = nil
        for index in snapshot.listenNow.indices {
            snapshot.listenNow[index].coverFile = nil
        }
        // Compare without volatile timestamps so position ticks don't flood the context.
        state?.capturedAt = .distantPast
        state?.currentTime = 0
        state?.displayedTime = 0
        state?.sleepTimerRemaining = nil
        let comparable = WatchPhoneContext(nowPlaying: state, snapshot: snapshot, sentAt: .distantPast)
        guard force || comparable != lastContext else { return }
        lastContext = comparable
        session.updateApplicationContext(.context(WatchPhoneContext(nowPlaying: Self.makeState(), snapshot: snapshot)))
    }

    /// Item / play state changes use the complication budget so the watch face updates promptly.
    private func pushComplicationIfNeeded(_ state: WatchNowPlayingState?) {
        let key = "\(state?.itemID.description ?? "-")|\(state?.isPlaying ?? false)"
        guard key != lastComplicationKey else { return }
        lastComplicationKey = key
        guard session.remainingComplicationTransfers > 5 else { return }
        var snapshot = HearthData.shared.snapshot.snapshot
        snapshot.nowPlaying?.coverFile = nil
        snapshot.listenNow = []
        session.transferComplicationInfo(.context(WatchPhoneContext(nowPlaying: state, snapshot: snapshot)))
    }

    // MARK: Credentials

    /// Sends new connections to an installed watch app.
    private func observeConnections() {
        withObservationTracking {
            _ = HearthData.shared.connections.connections.map(\.id)
            _ = HearthData.shared.connections.connectionNeedingReauthorization
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.connectionsChanged()
                self?.observeConnections()
            }
        }
        knownConnectionIDs = Set(HearthData.shared.connections.connections.map(\.id))
    }

    private func connectionsChanged() {
        let store = HearthData.shared.connections
        let ids = Set(store.connections.map(\.id))
        let added = ids.subtracting(knownConnectionIDs)
        knownConnectionIDs = ids
        if !added.isEmpty {
            pushCredentials(for: added)
        }
        if let id = store.connectionNeedingReauthorization {
            Task { await requestCredentialsFromWatch(for: id) }
        }
    }

    /// Polls for refreshed tokens (cheap: in-memory cache) and forwards them to the watch.
    private func startTokenMonitoring() {
        tokenTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.checkTokens()
            }
        }
    }

    private func checkTokens() {
        let changed = HearthData.shared.connections.changedTokenConnections()
        guard !changed.isEmpty else { return }
        pushCredentials(for: changed)
    }

    private func pushCredentials(for ids: Set<ConnectionID>) {
        guard session.activation == .activated else { return }
        guard session.isWatchAppInstalled else { return }
        let credentials = HearthData.shared.connections.watchCredentials(for: ids)
        guard !credentials.entries.isEmpty else { return }
        logger.info("Forwarding credentials of \(credentials.entries.count) connection(s) to the watch")
        session.transfer(.credentials(credentials))
    }

    /// The phone's refresh token was rejected – the watch may hold a newer one.
    private func requestCredentialsFromWatch(for id: ConnectionID) async {
        guard session.isReachable else { return }
        do {
            if case .credentials(let credentials) = try await session.send(.credentialsRequest) {
                let applied = await HearthData.shared.connections.applyWatchCredentials(credentials)
                if applied.contains(id) {
                    logger.info("Recovered tokens from the watch")
                }
            }
        } catch {
            logger.debug("Requesting credentials from the watch failed: \(String(describing: error), privacy: .public)")
        }
    }
}
