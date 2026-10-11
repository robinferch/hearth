import Foundation
import HearthData
import HearthModel
import HearthPlayback
import Observation
import OSLog

/// Watch side of the iPhone connection: credentials, the phone's player state, remote commands and the
/// complication snapshot mirrored from the phone.
@MainActor
@Observable
final class PhoneLink {
    static let shared = PhoneLink()

    /// The phone's player state (`nil` = idle or unknown).
    private(set) var state: WatchNowPlayingState?
    /// The phone's widget snapshot (Listen Now, listened today).
    private(set) var phoneSnapshot: SharedSnapshot?
    private(set) var isRequestingCredentials = false
    /// Set when a remote command failed; the UI shows it once.
    var commandFailure: WatchCommandFailure?

    @ObservationIgnored private let session = WatchSyncSession.shared
    @ObservationIgnored private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hearth", category: "PhoneLink")
    @ObservationIgnored private var didActivate = false
    @ObservationIgnored private var tokenTask: Task<Void, Never>?
    @ObservationIgnored private var lastMirroredKey: String?
    @ObservationIgnored private var lastCredentialRequest: Date?

    private init() {}

    /// Whether the iPhone app can receive live messages right now.
    var isReachable: Bool { session.isReachable }

    /// Whether remote control of the phone is possible (the phone has an item and can be reached or recently was).
    var isPhoneActive: Bool {
        guard let state else { return false }
        return isReachable || Date.now.timeIntervalSince(state.capturedAt) < 15 * 60
    }

    func activate() {
        guard !didActivate else { return }
        didActivate = true
        session.messageHandler = { [weak self] message in
            await self?.handle(message)
        }
        session.stateHandler = { [weak self] in
            self?.sessionStateChanged()
        }
        session.activate()
        startTokenMonitoring()
        observeReauthorization()
    }

    // MARK: Incoming

    private func handle(_ message: WatchSyncMessage) async -> WatchSyncMessage? {
        switch message {
        case .credentialsRequest:
            // The phone lost its session; our tokens may be newer.
            return .credentials(HearthData.shared.connections.watchCredentials())
        case .credentials(let credentials):
            await HearthData.shared.connections.applyWatchCredentials(credentials)
            return .acknowledged
        case .nowPlayingState(let state):
            apply(state)
            return nil
        case .context(let context):
            // Application contexts can arrive late (e.g. at launch). Never let one replace a newer live state –
            // also not an idle (`nil`) one, which is dated by when the context was sent.
            if let current = self.state, current.capturedAt > (context.nowPlaying?.capturedAt ?? context.sentAt) {
                // A live message already delivered something newer.
            } else {
                apply(context.nowPlaying)
            }
            if let snapshot = context.snapshot {
                phoneSnapshot = snapshot
                mirrorListenedToday(snapshot)
            }
            return nil
        case .command:
            return .commandResult(WatchCommandResult(failure: .failed, state: nil))
        case .nowPlayingRequest, .commandResult, .acknowledged:
            return nil
        }
    }

    private func sessionStateChanged() {
        guard session.activation == .activated, session.isReachable else { return }
        Task { await refresh() }
        if HearthData.shared.connections.signedInConnections.isEmpty {
            Task { _ = try? await requestCredentials() }
        }
    }

    private func apply(_ newState: WatchNowPlayingState?) {
        state = newState
        mirrorIntoSnapshot()
    }

    // MARK: Requests

    /// Asks the phone for the current player state.
    func refresh() async {
        guard session.isReachable else { return }
        do {
            if case .nowPlayingState(let state) = try await session.send(.nowPlayingRequest) {
                apply(state)
            }
        } catch {
            logger.debug("Requesting the phone's state failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Requests connections + tokens from the phone. Returns the number of connections applied.
    @discardableResult
    func requestCredentials() async throws -> Int {
        guard !isRequestingCredentials else { return 0 }
        isRequestingCredentials = true
        defer { isRequestingCredentials = false }
        lastCredentialRequest = .now
        await session.waitUntilActivated()
        let reply = try await session.send(.credentialsRequest)
        guard case .credentials(let credentials) = reply else { throw WatchSyncError.invalidReply }
        let applied = await HearthData.shared.connections.applyWatchCredentials(credentials)
        logger.info("Received \(credentials.entries.count) connection(s) from the phone, applied \(applied.count)")
        return applied.count
    }

    /// Sends a remote command; updates the state from the reply. Returns `false` on failure.
    @discardableResult
    func send(_ command: WatchCommand) async -> Bool {
        applyOptimistically(command)
        do {
            let reply = try await session.send(.command(command))
            guard case .commandResult(let result) = reply else { return false }
            apply(result.state)
            if let failure = result.failure {
                commandFailure = failure
                return false
            }
            return true
        } catch {
            logger.error("Remote command failed: \(String(describing: error), privacy: .public)")
            commandFailure = .failed
            await refresh()
            return false
        }
    }

    /// Immediate feedback for the most common commands; the reply replaces it.
    private func applyOptimistically(_ command: WatchCommand) {
        guard var state else { return }
        let now = Date.now
        state.currentTime = state.currentTime(at: now)
        state.displayedTime = state.displayedTime(at: now)
        state.sleepTimerRemaining = state.sleepTimerRemaining(at: now)
        state.capturedAt = now
        switch command {
        case .play: state.isPlaying = true
        case .pause: state.isPlaying = false
        case .togglePlayPause: state.isPlaying.toggle()
        case .setPlaybackRate(let rate): state.playbackRate = rate
        case .cancelSleepTimer:
            state.sleepTimer = nil
            state.sleepTimerRemaining = nil
        default: return
        }
        self.state = state
    }

    // MARK: Tokens

    /// Forwards refreshed tokens to the phone (audiobookshelf rotates refresh tokens).
    private func startTokenMonitoring() {
        tokenTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.checkTokens()
            }
        }
    }

    func checkTokens() {
        let connections = HearthData.shared.connections
        let changed = connections.changedTokenConnections()
        guard !changed.isEmpty, session.activation == .activated else { return }
        let credentials = connections.watchCredentials(for: changed)
        guard !credentials.entries.isEmpty else { return }
        session.transfer(.credentials(credentials))
    }

    /// When a refresh token is rejected, the phone usually has the current pair.
    private func observeReauthorization() {
        withObservationTracking {
            _ = HearthData.shared.connections.connectionNeedingReauthorization
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if HearthData.shared.connections.connectionNeedingReauthorization != nil,
                   Date.now.timeIntervalSince(self.lastCredentialRequest ?? .distantPast) > 30 {
                    _ = try? await self.requestCredentials()
                }
                self.observeReauthorization()
            }
        }
    }

    // MARK: Complication snapshot

    /// Shows the phone's item in the watch complications while the watch itself isn't playing.
    private func mirrorIntoSnapshot() {
        guard !AudioPlayer.shared.isActive else { return }
        let store = HearthData.shared.snapshot
        guard let state else {
            if lastMirroredKey != nil, store.snapshot.isPlaying {
                store.update { $0.isPlaying = false }
            }
            lastMirroredKey = nil
            return
        }
        let key = "\(state.itemID)|\(state.isPlaying)|\(state.chapterIndex ?? -1)|\(Int(state.currentTime / 60))|\(state.sleepTimer.map { "\($0)" } ?? "")"
        guard key != lastMirroredKey else { return }
        lastMirroredKey = key

        let existingCover = store.snapshot.nowPlaying?.id == state.itemID ? store.snapshot.nowPlaying?.coverFile : nil
        let entry = SharedSnapshot.Entry(
            id: state.itemID,
            title: state.title,
            subtitle: state.subtitle,
            progress: state.progress,
            remaining: state.duration > 0 ? max(0, state.duration - state.currentTime) : nil,
            isDownloaded: HearthData.shared.downloads.status(of: state.itemID) == .completed,
            coverFile: existingCover
        )
        store.update { snapshot in
            snapshot.nowPlaying = entry
            snapshot.isPlaying = state.isPlaying
            snapshot.chapterTitle = state.chapterTitle
            snapshot.sleepTimer = state.sleepTimer
        }
        if existingCover == nil {
            let id = state.itemID
            Task {
                guard let file = await store.storeCover(for: id), store.snapshot.nowPlaying?.id == id else { return }
                store.update { $0.nowPlaying?.coverFile = file }
            }
        }
    }

    private func mirrorListenedToday(_ snapshot: SharedSnapshot) {
        let store = HearthData.shared.snapshot
        let listened = max(snapshot.listenedToday, HearthData.shared.listening.listenedToday)
        guard listened > store.snapshot.listenedToday else { return }
        store.update { $0.listenedToday = listened }
    }
}

extension WatchCommandFailure {
    var localizedDescription: String {
        switch self {
        case .nothingPlaying: String(localized: "Nothing is playing on your iPhone.")
        case .notPlayable: String(localized: "This item can't be played.")
        case .downloadInProgress: String(localized: "This item is currently downloading on your iPhone.")
        case .itemUnavailable: String(localized: "Your iPhone couldn't load this item.")
        case .bookmarkUnsupported: String(localized: "Bookmarks are only available for audiobooks.")
        case .failed: String(localized: "Your iPhone didn't respond. Make sure Hearth is running on it.")
        }
    }
}
