import Foundation
import HearthData
import HearthModel

/// Bookmarks and finished state.
extension AudioPlayer {
    func performCreateBookmark(note: String?) async throws -> Bookmark {
        guard let item = currentItem else { throw PlaybackError.noPlaybackItem }
        guard case .audiobook = item else { throw PlaybackError.notPlayable }
        let time = currentTime.rounded(.down)
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = trimmed.isEmpty ? Self.quickBookmarkNote(for: .now) : trimmed
        return try await HearthData.shared.bookmarks.create(item.id, time: time, note: text)
    }

    /// Note used for quick bookmarks: the formatted date/time.
    nonisolated static func quickBookmarkNote(for date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    func performSetFinished(_ id: ItemIdentifier, finished: Bool) async throws {
        if finished, isCurrent(id), duration > 0 {
            // Seeking to the end runs the normal finish flow (report, close, advance).
            await seekInternal(to: duration)
            return
        }
        try await HearthData.shared.progress.setFinished(id, finished: finished)
        if finished {
            pruneFinishedItems(also: id)
            if lastPlayedItemID == id, currentItem == nil {
                lastPlayedItemID = nil
                PlaybackPersistence.lastPlayedItemID = nil
            }
        }
    }
}
