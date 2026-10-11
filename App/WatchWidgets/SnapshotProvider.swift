import Foundation
import HearthData
import HearthModel
import HearthUI
import SwiftUI
import UIKit
import WidgetKit

/// Timeline entry built from the shared snapshot the watch app writes (local playback and the phone's state).
struct SnapshotEntry: TimelineEntry, Sendable {
    let date: Date
    let snapshot: SharedSnapshot
    let relevanceScore: Float?

    var relevance: TimelineEntryRelevance? { relevanceScore.map { TimelineEntryRelevance(score: $0) } }

    /// The item to show: now playing, else the first Listen Now item.
    var item: SharedSnapshot.Entry? { snapshot.nowPlaying ?? snapshot.listenNow.first }
    var isNowPlaying: Bool { snapshot.nowPlaying != nil }
    /// The player rewrites the snapshot at least every 30 s while playing; an older "playing" state is stale
    /// (e.g. the app was terminated without pausing).
    var isPlaying: Bool {
        snapshot.isPlaying && snapshot.nowPlaying != nil && date.timeIntervalSince(snapshot.updatedAt) < 5 * 60
    }

    /// Minutes listened today; 0 when the snapshot is from an earlier day.
    var listenedMinutes: Int {
        Calendar.current.isDate(snapshot.updatedAt, inSameDayAs: date) ? Int(snapshot.listenedToday / 60) : 0
    }

    var goalMinutes: Int { max(1, snapshot.dailyGoalMinutes) }

    var tint: Color { snapshot.tint.color }

    /// Opens the player while playing, else the item (the watch shows the player if the item is loaded there,
    /// its detail otherwise). A paused or stale "now playing" item may no longer be in the player.
    var url: URL? {
        guard let item else { return URL(string: "hearth://home") }
        let encoded = item.id.description.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? item.id.description
        if isPlaying {
            return URL(string: "hearth://nowplaying/\(encoded)")
        }
        return URL(string: "hearth://item/\(encoded)")
    }

    /// Small cover from the snapshot images directory.
    var cover: UIImage? {
        guard let file = item?.coverFile else { return nil }
        return UIImage(contentsOfFile: SharedSnapshotStore.coverURL(file).path)
    }

    static let preview = SnapshotEntry(
        date: .now,
        snapshot: SharedSnapshot(
            nowPlaying: SharedSnapshot.Entry(
                id: ItemIdentifier(kind: .audiobook, connectionID: "preview", libraryID: "library", primaryID: "book"),
                title: String(localized: "The Hobbit"),
                subtitle: "J. R. R. Tolkien",
                progress: 0.42,
                remaining: 3 * 3600 + 12 * 60,
                isDownloaded: true,
                coverFile: nil
            ),
            isPlaying: true,
            chapterTitle: String(localized: "Chapter 5"),
            listenedToday: 18 * 60,
            dailyGoalMinutes: 30
        ),
        relevanceScore: nil
    )
}

enum NowPlayingRelevance {
    /// Smart Stack: playing → top, recently played → medium, otherwise low.
    static func score(for snapshot: SharedSnapshot, at date: Date) -> Float {
        if snapshot.isPlaying, snapshot.nowPlaying != nil, date.timeIntervalSince(snapshot.updatedAt) < 5 * 60 {
            return 100
        }
        if snapshot.nowPlaying != nil, date.timeIntervalSince(snapshot.updatedAt) < 6 * 3600 {
            return 40
        }
        return snapshot.listenNow.isEmpty ? 0 : 10
    }
}

struct SnapshotProvider: TimelineProvider {
    /// Relevance function for the widget kind.
    let relevance: @Sendable (SharedSnapshot, Date) -> Float

    func placeholder(in context: Context) -> SnapshotEntry {
        .preview
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        if context.isPreview {
            completion(.preview)
            return
        }
        let snapshot = SharedSnapshotStore.read()
        completion(SnapshotEntry(date: .now, snapshot: snapshot, relevanceScore: relevance(snapshot, .now)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let now = Date.now
        let snapshot = SharedSnapshotStore.read()
        var entries = [SnapshotEntry(date: now, snapshot: snapshot, relevanceScore: relevance(snapshot, now))]

        // Listened today resets at midnight.
        let midnight = Calendar.current.startOfDay(for: now.addingTimeInterval(24 * 3600))
        entries.append(SnapshotEntry(date: midnight, snapshot: snapshot, relevanceScore: relevance(snapshot, midnight)))

        // A "playing" state that isn't refreshed turns stale after 5 minutes.
        if snapshot.isPlaying {
            let stale = snapshot.updatedAt.addingTimeInterval(5 * 60 + 1)
            if stale > now, stale < midnight {
                entries.insert(SnapshotEntry(date: stale, snapshot: snapshot, relevanceScore: relevance(snapshot, stale)), at: 1)
            }
        }

        // While playing, the app reloads timelines on changes; refresh periodically as a fallback.
        let refresh = snapshot.isPlaying ? now.addingTimeInterval(15 * 60) : midnight
        completion(Timeline(entries: entries, policy: .after(refresh)))
    }
}
