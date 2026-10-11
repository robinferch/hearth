import Foundation
import HearthAPI
import HearthModel
import Observation
import os
import SwiftData

/// Listening time (daily goal), local sessions recorded while offline, and the registry of open server sessions.
///
/// `listenedToday` = server sessions updated since local midnight (all connections)
///                 + local sessions not yet uploaded (today)
///                 + time reported to the server since the last fetch (`addUnreported`).
@MainActor
@Observable
public final class ListeningTracker {
    /// Seconds listened today (server + local + current unreported).
    public internal(set) var listenedToday: TimeInterval = 0 {
        didSet {
            if oldValue != listenedToday {
                hearth?.listenedTodayChanged()
            }
        }
    }

    struct OpenSession: Codable, Sendable, Hashable {
        var sessionID: String
        var itemID: ItemIdentifier
        var openedAt: Date
    }

    @ObservationIgnored private var day: Date
    @ObservationIgnored private var serverToday: TimeInterval = 0
    @ObservationIgnored private var unreported: TimeInterval = 0
    @ObservationIgnored private var localSessions: [String: LocalSessionRecord] = [:]
    /// Open (not yet closed) local session per item storage key.
    @ObservationIgnored private var openLocal: [String: String] = [:]
    @ObservationIgnored private var openSessions: [String: OpenSession] = [:]
    @ObservationIgnored private var sessionsOpenedThisLaunch = Set<String>()
    @ObservationIgnored private var midnightTask: Task<Void, Never>?
    @ObservationIgnored private var dayObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var isUploading = false
    @ObservationIgnored private lazy var cachedDeviceInfo = DeviceInfoProvider.make(defaults: environment.defaults)

    @ObservationIgnored let environment: DataEnvironment
    @ObservationIgnored weak var hearth: HearthData?
    @ObservationIgnored private let logger = Logger(category: "ListeningTracker")

    private enum Key {
        static let openSessions = "listening.openSessions"
        static let serverToday = "listening.serverToday"
        static let serverTodayDay = "listening.serverTodayDay"
    }

    /// Open local sessions untouched for this long are considered abandoned and uploaded.
    static let staleLocalSessionInterval: TimeInterval = 3600
    /// Open server sessions older than this are dropped even if closing fails.
    static let maxOpenSessionAge: TimeInterval = 3 * 86_400

    init(environment: DataEnvironment) {
        self.environment = environment
        day = Calendar.current.startOfDay(for: .now)
        if let storedDay = environment.defaults.object(forKey: Key.serverTodayDay) as? Date, Calendar.current.isDate(storedDay, inSameDayAs: .now) {
            serverToday = environment.defaults.double(forKey: Key.serverToday)
        }
        if let data = environment.defaults.data(forKey: Key.openSessions), let sessions = JSON.decode([OpenSession].self, from: data) {
            openSessions = Dictionary(sessions.map { ($0.sessionID, $0) }, uniquingKeysWith: { $1 })
        }
        for session in ModelContext(environment.container).localSessions() {
            localSessions[session.id] = session
            if !session.isClosed {
                openLocal[session.itemID.storageKey] = session.id
            }
        }
        recompute()

        if environment.isLive {
            scheduleMidnightReset()
            dayObserver = NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.rollDayIfNeeded()
                    Task { await self.refresh() }
                }
            }
        }
    }

    // MARK: Listened today

    private var localToday: TimeInterval {
        localSessions.values.filter { $0.updatedAt >= day }.reduce(0) { $0 + $1.timeListened }
    }

    private func recompute() {
        listenedToday = max(0, serverToday + localToday + unreported)
    }

    private func rollDayIfNeeded() {
        let today = Calendar.current.startOfDay(for: .now)
        guard today != day else { return }
        day = today
        serverToday = 0
        unreported = 0
        persistServerToday()
        recompute()
    }

    private func persistServerToday() {
        environment.defaults.set(serverToday, forKey: Key.serverToday)
        environment.defaults.set(day, forKey: Key.serverTodayDay)
    }

    private func scheduleMidnightReset() {
        midnightTask?.cancel()
        let next = Calendar.current.startOfNextDay(after: .now)
        midnightTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow + 1)))
            guard !Task.isCancelled, let self else { return }
            self.rollDayIfNeeded()
            await self.refresh()
            self.scheduleMidnightReset()
        }
    }

    public func refresh() async {
        rollDayIfNeeded()
        guard let hearth, !hearth.connections.isOffline else {
            recompute()
            return
        }
        let midnight = day
        let clients = hearth.connections.availableClients()
        guard !clients.isEmpty else {
            recompute()
            return
        }
        let totals = await concurrentCompactMap(clients) { client in
            try? await Self.serverTime(client: client, since: midnight)
        }
        guard !totals.isEmpty, Calendar.current.isDate(midnight, inSameDayAs: .now) else {
            recompute()
            return
        }
        serverToday = totals.reduce(0, +)
        unreported = 0
        persistServerToday()
        recompute()
    }

    /// Sum of `timeListening` of sessions updated since `midnight` (paged; sessions are newest first).
    nonisolated static func serverTime(client: any AudiobookshelfClient, since midnight: Date, perPage: Int = 50, maxPages: Int = 10) async throws -> TimeInterval {
        var total: TimeInterval = 0
        for page in 0..<maxPages {
            let result = try await client.listeningSessions(page: page, perPage: perPage)
            total += result.items.filter { $0.updatedAt >= midnight }.reduce(0) { $0 + $1.timeListening }
            let sortedDescending = zip(result.items, result.items.dropFirst()).allSatisfy { $0.updatedAt >= $1.updatedAt }
            let reachedOlder = result.items.last.map { $0.updatedAt < midnight } ?? true
            if result.items.isEmpty || (page + 1) * perPage >= result.total || (sortedDescending && reachedOlder) {
                break
            }
        }
        return total
    }

    /// Adds time (delta in seconds) the player reported to a server session (`sync`/`close`) since the last
    /// `refresh()`. The server total fetched by `refresh()` already contains it, so the bucket is reset there.
    /// Time recorded through `recordLocalSession` is counted separately and must not be passed here.
    public func addUnreported(_ seconds: TimeInterval) {
        guard seconds > 0, seconds.isFinite else { return }
        rollDayIfNeeded()
        unreported += seconds
        recompute()
    }

    // MARK: Local sessions

    /// Records listening that couldn't be reported to a server session. `timeListened` is the delta since the
    /// previous call for this item.
    public func recordLocalSession(itemID: ItemIdentifier, startTime: TimeInterval, currentTime: TimeInterval, duration: TimeInterval, timeListened: TimeInterval) async {
        rollDayIfNeeded()
        let delta = max(0, timeListened.isFinite ? timeListened : 0)
        let key = itemID.storageKey
        var session: LocalSessionRecord
        if let id = openLocal[key], let existing = localSessions[id], Calendar.current.isDate(existing.startedAt, inSameDayAs: .now) {
            session = existing
            session.currentTime = currentTime
            session.duration = duration > 0 ? duration : existing.duration
            session.timeListened += delta
            session.updatedAt = .now
        } else {
            if let previous = openLocal[key], var stale = localSessions[previous] {
                // A new day starts a new session (the server groups sessions by day).
                stale.isClosed = true
                localSessions[previous] = stale
                let closed = stale
                await environment.store.perform { $0.upsertLocalSession(closed) }
            }
            session = LocalSessionRecord(id: UUID().uuidString.lowercased(), itemID: itemID, startTime: startTime, currentTime: currentTime, duration: duration, timeListened: delta, startedAt: Date.now.addingTimeInterval(-delta), updatedAt: .now, isClosed: false)
            openLocal[key] = session.id
        }
        localSessions[session.id] = session
        recompute()
        let record = session
        await environment.store.perform { $0.upsertLocalSession(record) }
    }

    public func closeLocalSession(itemID: ItemIdentifier) async {
        let key = itemID.storageKey
        guard let id = openLocal.removeValue(forKey: key), var session = localSessions[id] else { return }
        session.isClosed = true
        localSessions[id] = session
        let record = session
        await environment.store.perform { $0.upsertLocalSession(record) }
        if session.timeListened <= 0 {
            await deleteLocalSession(id)
            return
        }
        await uploadPendingSessions()
    }

    private func deleteLocalSession(_ id: String) async {
        if let session = localSessions.removeValue(forKey: id), openLocal[session.itemID.storageKey] == id {
            openLocal[session.itemID.storageKey] = nil
        }
        await environment.store.perform { $0.deleteLocalSession(id: id) }
        recompute()
    }

    /// Uploads closed (and abandoned) local sessions via `api/session/local`.
    public func uploadPendingSessions() async {
        guard let hearth, !hearth.connections.isOffline, !isUploading else { return }
        isUploading = true
        defer { isUploading = false }
        let device = deviceInfo
        let now = Date.now
        let candidates = localSessions.values.filter { $0.isClosed || now.timeIntervalSince($0.updatedAt) > Self.staleLocalSessionInterval }
        for candidate in candidates.sorted(by: { $0.startedAt < $1.startedAt }) {
            // Re-read: listening may have been recorded while an earlier upload was in flight.
            guard var session = localSessions[candidate.id] else { continue }
            guard hearth.connections.isAvailable(session.itemID.connectionID), let client = try? hearth.connections.client(for: session.itemID.connectionID) else { continue }
            guard session.timeListened > 0 else {
                await deleteLocalSession(session.id)
                continue
            }
            if !session.isClosed {
                // Close an abandoned session before uploading it: listening recorded during the upload then goes
                // into a new session instead of being deleted together with this one.
                session.isClosed = true
                localSessions[session.id] = session
                if openLocal[session.itemID.storageKey] == session.id {
                    openLocal[session.itemID.storageKey] = nil
                }
                let closed = session
                await environment.store.perform { $0.upsertLocalSession(closed) }
            }
            do {
                try await client.uploadLocalSession(session.upload, device: device)
                if session.updatedAt >= day {
                    // Counted by the server now; keep the total stable until the next refresh.
                    serverToday += session.timeListened
                    persistServerToday()
                }
                await deleteLocalSession(session.id)
            } catch {
                logger.error("Uploading local session failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Open server sessions

    public func registerOpenSession(_ sessionID: String, itemID: ItemIdentifier) {
        openSessions[sessionID] = OpenSession(sessionID: sessionID, itemID: itemID, openedAt: .now)
        sessionsOpenedThisLaunch.insert(sessionID)
        persistOpenSessions()
    }

    public func unregisterOpenSession(_ sessionID: String) {
        guard openSessions.removeValue(forKey: sessionID) != nil else { return }
        sessionsOpenedThisLaunch.remove(sessionID)
        persistOpenSessions()
    }

    private func persistOpenSessions() {
        environment.defaults.set(JSON.encode(Array(openSessions.values)), forKey: Key.openSessions)
    }

    /// Closes server sessions left open by a previous run (crash, termination while playing).
    ///
    /// The sessions are closed without a position: a close with sync data is applied as a progress update with
    /// `lastUpdate = now`, which would overwrite progress made on other devices since. Progress recorded locally
    /// is pushed by the progress sync instead.
    public func closeStaleSessions() async {
        guard let hearth else { return }
        let stale = openSessions.values.filter { !sessionsOpenedThisLaunch.contains($0.sessionID) }
        for session in stale {
            if Date.now.timeIntervalSince(session.openedAt) > Self.maxOpenSessionAge {
                unregisterOpenSession(session.sessionID)
                continue
            }
            guard hearth.connections.connection(session.itemID.connectionID) != nil else {
                unregisterOpenSession(session.sessionID)
                continue
            }
            guard hearth.connections.isAvailable(session.itemID.connectionID), let client = try? hearth.connections.client(for: session.itemID.connectionID) else { continue }
            do {
                try await client.closeSession(session.sessionID)
                unregisterOpenSession(session.sessionID)
            } catch APIError.notFound {
                unregisterOpenSession(session.sessionID)
            } catch {
                logger.error("Closing stale session failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func forget(connection: ConnectionID) {
        for session in openSessions.values where session.itemID.connectionID == connection {
            openSessions[session.sessionID] = nil
        }
        persistOpenSessions()
        for session in localSessions.values where session.itemID.connectionID == connection {
            localSessions[session.id] = nil
            openLocal[session.itemID.storageKey] = nil
        }
        recompute()
    }

    // MARK: History & stats

    public func listeningSessions(for id: ItemIdentifier) async throws -> [ListeningSession] {
        guard let hearth else { throw APIError.unreachable }
        let client = try hearth.connections.client(for: id.connectionID)
        var sessions = [ListeningSession]()
        for page in 0..<5 {
            let result = try await client.listeningSessions(for: id, page: page, perPage: 100)
            sessions += result.items
            if result.items.isEmpty || sessions.count >= result.total {
                break
            }
        }
        return sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func stats(connection: ConnectionID) async throws -> ListeningStats {
        guard let hearth else { throw APIError.unreachable }
        return try await hearth.connections.client(for: connection).listeningStats()
    }

    /// Persistent random device id + model info sent with sessions.
    public var deviceInfo: DeviceInfo {
        cachedDeviceInfo
    }
}
