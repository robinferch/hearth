import Foundation
import HearthModel

// MARK: Playback sessions & listening history

extension APIClient {
    func startSession(_ id: ItemIdentifier, device: DeviceInfo) async throws -> PlaybackSessionInfo {
        var path = ["api", "items", id.apiItemID, "play"]
        if let episodeID = id.apiEpisodeID {
            path.append(episodeID)
        }
        let request = try APIRequest(method: .post, path: path).json(StartSessionBody(deviceInfo: DeviceInfoBody(device, includeOS: true)))
        let payload = try await fetch(PlaybackSessionPayload.self, request)
        if let item = payload.libraryItem {
            converter.register(item, library: id.libraryID)
        }
        return converter.playbackSession(payload)
    }

    func syncSession(_ sessionID: String, currentTime: TimeInterval, duration: TimeInterval, timeListened: TimeInterval) async throws {
        let body = SessionSyncBody(duration: duration, currentTime: currentTime, timeListened: max(0, timeListened))
        // Sets the position; a repeated sync at worst adds `timeListened` twice, which beats losing the report.
        try await perform(APIRequest.post("api", "session", sessionID, "sync").json(body).idempotent())
    }

    func closeSession(_ sessionID: String, currentTime: TimeInterval, duration: TimeInterval, timeListened: TimeInterval) async throws {
        let body = SessionSyncBody(duration: duration, currentTime: currentTime, timeListened: max(0, timeListened))
        try await perform(APIRequest.post("api", "session", sessionID, "close").json(body))
    }

    func uploadLocalSession(_ session: LocalSessionUpload, device: DeviceInfo) async throws {
        var userID = connection.userID
        if userID == nil {
            userID = try? await me().userID
        }
        let body = LocalSessionBody(session, userID: userID, device: device)
        try await perform(APIRequest.post("api", "session", "local").json(body))
    }

    func listeningSessions(page: Int, perPage: Int) async throws -> Page<ListeningSession> {
        try await listeningSessions(APIRequest.get("api", "me", "listening-sessions", query: Self.sessionPageQuery(page: page, perPage: perPage)), page: page)
    }

    func listeningSessions(for id: ItemIdentifier, page: Int, perPage: Int) async throws -> Page<ListeningSession> {
        var path = ["api", "me", "item", "listening-sessions", id.apiItemID]
        if let episodeID = id.apiEpisodeID {
            path.append(episodeID)
        }
        return try await listeningSessions(APIRequest(method: .get, path: path, query: Self.sessionPageQuery(page: page, perPage: perPage)), page: page)
    }

    private func listeningSessions(_ request: APIRequest, page: Int) async throws -> Page<ListeningSession> {
        let payload = try await fetch(ListeningSessionsPayload.self, request)
        let sessions = payload.sessions.map(converter.listeningSession)
        return Page(items: sessions, total: payload.total ?? sessions.count, page: payload.page ?? page)
    }

    private static func sessionPageQuery(page: Int, perPage: Int) -> [URLQueryItem] {
        [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "itemsPerPage", value: String(perPage))]
    }

    func listeningStats() async throws -> ListeningStats {
        converter.listeningStats(try await fetch(ListeningStatsPayload.self, .get("api", "me", "listening-stats")))
    }
}
