import Foundation
import HearthAPI
import HearthData
import HearthModel
import os

/// Pure listening-time accounting: wall-clock time while playing, drained in deltas.
struct ListeningClock: Sendable, Hashable {
    static let firstReportDelay: TimeInterval = 3
    static let reportInterval: TimeInterval = 30

    private(set) var playingSince: Date?
    private(set) var accumulated: TimeInterval = 0
    private(set) var lastReport: Date?
    private(set) var hasReported = false

    var isRunning: Bool { playingSince != nil }

    mutating func start(at now: Date) {
        guard playingSince == nil else { return }
        playingSince = now
        if lastReport == nil {
            lastReport = now
        }
    }

    mutating func stop(at now: Date) {
        guard let playingSince else { return }
        accumulated += max(0, now.timeIntervalSince(playingSince))
        self.playingSince = nil
    }

    func unreported(at now: Date) -> TimeInterval {
        accumulated + (playingSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    /// Whether a periodic report is due (first after ~3 s, then every 30 s of playback).
    func isReportDue(at now: Date) -> Bool {
        guard isRunning, let lastReport else { return false }
        let interval = hasReported ? Self.reportInterval : Self.firstReportDelay
        return now.timeIntervalSince(lastReport) >= interval
    }

    /// Returns the listened delta since the previous drain and resets it.
    mutating func drain(at now: Date) -> TimeInterval {
        let value = unreported(at: now)
        accumulated = 0
        if playingSince != nil {
            playingSince = now
        }
        lastReport = now
        hasReported = true
        return value
    }
}

/// Reports listening progress for one playback run (spec §3).
///
/// Server session → `session/{id}/sync`; without a session or when the sync fails the delta is recorded
/// as a local session. Local progress is always updated. All network work is serialized on a task chain
/// so the player never waits for it.
@MainActor
final class SessionReporter {
    let itemID: ItemIdentifier
    let sessionID: String?
    let client: (any AudiobookshelfClient)?
    let startTime: TimeInterval
    var duration: TimeInterval

    private var clock = ListeningClock()
    private var chain: Task<Void, Never>?
    private var isFinalized = false
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.robinferch.hearth", category: "SessionReporter")

    init(itemID: ItemIdentifier, sessionID: String?, client: (any AudiobookshelfClient)?, startTime: TimeInterval, duration: TimeInterval) {
        self.itemID = itemID
        self.sessionID = sessionID
        self.client = client
        self.startTime = startTime
        self.duration = duration
        if let sessionID {
            HearthData.shared.listening.registerOpenSession(sessionID, itemID: itemID)
        }
    }

    func didStartPlaying(at currentTime: TimeInterval) {
        guard !isFinalized else { return }
        clock.start(at: .now)
    }

    /// Pause: stops the clock and reports (when anything was listened or the position changed).
    func didStopPlaying(at currentTime: TimeInterval) {
        guard !isFinalized, clock.isRunning else { return }
        clock.stop(at: .now)
        report(currentTime: currentTime)
    }

    /// Called from the periodic time observer.
    func tick(currentTime: TimeInterval) {
        guard !isFinalized, clock.isReportDue(at: .now) else { return }
        report(currentTime: currentTime)
    }

    /// Updates local progress only (seeks while paused).
    func positionChanged(to currentTime: TimeInterval) {
        guard !isFinalized else { return }
        let itemID = itemID
        let duration = duration
        enqueue {
            await HearthData.shared.progress.update(itemID, currentTime: currentTime, duration: duration)
        }
    }

    func report(currentTime: TimeInterval) {
        guard !isFinalized else { return }
        let listened = clock.drain(at: .now)
        let itemID = itemID
        let sessionID = sessionID
        let client = client
        let startTime = startTime
        let duration = duration
        let logger = logger
        enqueue {
            await Self.send(itemID: itemID, sessionID: sessionID, client: client, startTime: startTime, currentTime: currentTime, duration: duration, listened: listened, close: false, logger: logger)
        }
    }

    /// Forced final report, closes the server session and marks the local session eligible for upload.
    func finalize(currentTime: TimeInterval, finished: Bool, then completion: (@MainActor () async -> Void)? = nil) {
        guard !isFinalized else { return }
        clock.stop(at: .now)
        let listened = clock.drain(at: .now)
        isFinalized = true
        let itemID = itemID
        let sessionID = sessionID
        let client = client
        let startTime = startTime
        let duration = duration
        let logger = logger
        let time = finished ? duration : currentTime
        enqueue {
            await Self.send(itemID: itemID, sessionID: sessionID, client: client, startTime: startTime, currentTime: time, duration: duration, listened: listened, close: true, logger: logger)
            await HearthData.shared.listening.closeLocalSession(itemID: itemID)
            if finished {
                do {
                    try await HearthData.shared.progress.setFinished(itemID, finished: true)
                } catch {
                    logger.error("Marking \(itemID, privacy: .public) finished failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            await completion?()
        }
    }

    /// Waits until all queued reports were handled (used before app suspension).
    func flush() async {
        await chain?.value
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    private static func send(itemID: ItemIdentifier, sessionID: String?, client: (any AudiobookshelfClient)?, startTime: TimeInterval, currentTime: TimeInterval, duration: TimeInterval, listened: TimeInterval, close: Bool, logger: Logger) async {
        let data = HearthData.shared
        await data.progress.update(itemID, currentTime: currentTime, duration: duration)

        if let sessionID, let client, !data.connections.isOffline {
            do {
                if close {
                    try await client.closeSession(sessionID, currentTime: currentTime, duration: duration, timeListened: listened)
                    data.listening.unregisterOpenSession(sessionID)
                } else {
                    try await client.syncSession(sessionID, currentTime: currentTime, duration: duration, timeListened: listened)
                }
                if listened > 0 {
                    data.listening.addUnreported(listened)
                }
                return
            } catch {
                logger.warning("Session \(close ? "close" : "sync", privacy: .public) failed, recording locally: \(error.localizedDescription, privacy: .public)")
            }
        }

        if listened > 0 {
            await data.listening.recordLocalSession(itemID: itemID, startTime: startTime, currentTime: currentTime, duration: duration, timeListened: listened)
        }
    }
}
