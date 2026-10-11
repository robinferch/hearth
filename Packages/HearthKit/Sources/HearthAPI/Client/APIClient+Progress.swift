import Foundation
import HearthModel

// MARK: Progress & bookmarks

extension APIClient {
    func batchUpdateProgress(_ entries: [ProgressEntity]) async throws {
        guard !entries.isEmpty else { return }
        try await perform(APIRequest.patch("api", "me", "progress", "batch", "update").json(entries.map(ProgressUpdateBody.init)).idempotent())
    }

    func deleteProgress(id: String) async throws {
        try await perform(APIRequest.delete("api", "me", "progress", id).idempotent())
    }

    func setFinished(_ id: ItemIdentifier, finished: Bool) async throws {
        try await perform(APIRequest(method: .patch, path: Self.progressPath(id)).json(FinishedBody(isFinished: finished)).idempotent())
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
        let request = try APIRequest.post("api", "me", "item", id.apiItemID, "bookmark").json(BookmarkBody(title: note, time: Double(time)))
        let payload = try await fetch(BookmarkPayload.self, request)
        bookmarkTimes.register(itemID: id.apiItemID, time: payload.time)
        return converter.bookmark(payload, itemID: id)
    }

    func updateBookmark(_ id: ItemIdentifier, time: Int, note: String) async throws {
        try await withExactBookmarkTime(id, second: time) { exact in
            try await perform(APIRequest.patch("api", "me", "item", id.apiItemID, "bookmark").json(BookmarkBody(title: note, time: exact)).idempotent())
        }
    }

    func deleteBookmark(_ id: ItemIdentifier, time: Int) async throws {
        try await withExactBookmarkTime(id, second: time) { exact in
            try await perform(APIRequest.delete("api", "me", "item", id.apiItemID, "bookmark", BookmarkTimeDirectory.pathComponent(exact)).idempotent())
        }
        bookmarkTimes.remove(itemID: id.apiItemID, second: time)
    }

    /// Runs `operation` with the server's exact time of the bookmark at `second`. The server matches bookmarks on
    /// that exact value; on 404 the bookmark list is reloaded once in case the bookmark has a fractional time that
    /// wasn't seen yet (created by another client since the last sync).
    private func withExactBookmarkTime(_ id: ItemIdentifier, second: Int, operation: (Double) async throws -> Void) async throws {
        let itemID = id.apiItemID
        let attempted = bookmarkTimes.exactTime(itemID: itemID, second: second)
        do {
            try await operation(attempted)
        } catch APIError.notFound {
            let user = try await fetch(UserPayload.self, .get("api", "me"))
            bookmarkTimes.register(user.bookmarks)
            let exact = bookmarkTimes.exactTime(itemID: itemID, second: second)
            guard exact != attempted else { throw APIError.notFound }
            try await operation(exact)
        }
    }
}
