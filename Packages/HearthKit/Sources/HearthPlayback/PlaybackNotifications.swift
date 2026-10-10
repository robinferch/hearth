import Foundation
import HearthModel

public extension AudioPlayer {
    /// Posted (main thread) when a new item started playing. `userInfo[itemIDKey]` = `ItemIdentifier.description`.
    nonisolated static let itemStartedNotification = Notification.Name("HearthPlayback.itemStarted")
    /// Posted when an item played to its end (or was marked finished while playing). `userInfo[itemIDKey]`.
    nonisolated static let itemFinishedNotification = Notification.Name("HearthPlayback.itemFinished")
    /// Posted when the sleep timer was set, changed, cancelled or expired (not on every tick).
    /// `userInfo[sleepTimerExpiredKey]` = `true` when it expired.
    nonisolated static let sleepTimerChangedNotification = Notification.Name("HearthPlayback.sleepTimerChanged")
    /// Posted when playback started/paused/stopped.
    nonisolated static let playbackStateChangedNotification = Notification.Name("HearthPlayback.playbackStateChanged")

    nonisolated static let itemIDKey = "itemID"
    nonisolated static let sleepTimerExpiredKey = "expired"

    /// Extracts the item identifier from one of the notifications above.
    nonisolated static func itemID(from notification: Notification) -> ItemIdentifier? {
        (notification.userInfo?[itemIDKey] as? String).flatMap(ItemIdentifier.init)
    }
}

extension AudioPlayer {
    func post(_ name: Notification.Name, itemID: ItemIdentifier? = nil, extra: [String: Any] = [:]) {
        var userInfo = extra
        if let itemID {
            userInfo[Self.itemIDKey] = itemID.description
        }
        NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
    }
}
