import Foundation
import HearthModel

// MARK: Progress & bookmarks

extension APIClient {
    func batchUpdateProgress(_ entries: [ProgressEntity]) async throws {
        guard !entries.isEmpty else { return }
        try await perform(APIRequest.patch("api", "me", "progress", "batch", "update").json(entries.map(ProgressUpdateBody.init)))
    }

    func deleteProgress(id: String) async throws {
        try await perform(.delete("api", "me", "progress", id))
    }

    func setFinished(_ id: ItemIdentifier, finished: Bool) async throws {
        try await perform(APIRequest(method: .patch, path: Self.progressPath(id)).json(FinishedBody(isFinished: finished)))
    }

    func hideFromContinueListening(progressID: String) async throws {
        var request = APIRequest.get("api", "me", "progress", progressID, "remove-from-continue-listening")
        request.retryable = false
        try await perform(request)
        await executor.invalidateCache()
    }

    /// `api/me/progress/{itemId}[/{episodeId}]`.
    static func progressPath(_ id: ItemIdentifier) -> [String] {
        var path = ["api", "me", "progress", id.apiItemID]
        if let episodeID = id.apiEpisodeID {
            path.append(episodeID)
        }
        return path
    }

    func createBookmark(_ id: ItemIdentifier, time: Int, note: String) async throws -> Bookmark {
        let request = try APIRequest.post("api", "me", "item", id.apiItemID, "bookmark").json(BookmarkBody(title: note, time: time))
        let payload = try await fetch(BookmarkPayload.self, request)
        return converter.bookmark(payload, itemID: id)
    }

    func updateBookmark(_ id: ItemIdentifier, time: Int, note: String) async throws {
        try await perform(APIRequest.patch("api", "me", "item", id.apiItemID, "bookmark").json(BookmarkBody(title: note, time: time)))
    }

    func deleteBookmark(_ id: ItemIdentifier, time: Int) async throws {
        try await perform(.delete("api", "me", "item", id.apiItemID, "bookmark", String(time)))
    }
}
