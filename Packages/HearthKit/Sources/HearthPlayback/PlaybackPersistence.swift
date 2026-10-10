import Foundation
import HearthData
import HearthModel

/// Player state persisted in the app-group defaults (readable by widgets / intents).
enum PlaybackPersistence {
    private static let lastPlayedKey = "playback.lastPlayedItemID"
    private static let lastPlayedOriginKey = "playback.lastPlayedOrigin"
    private static let queueKey = "playback.queue"

    static var defaults: UserDefaults { AppGroup.defaults }

    static var lastPlayedItemID: ItemIdentifier? {
        get { defaults.string(forKey: lastPlayedKey).flatMap(ItemIdentifier.init) }
        set { defaults.set(newValue?.description, forKey: lastPlayedKey) }
    }

    static var lastPlayedOrigin: PlaybackOrigin? {
        get {
            guard let data = defaults.data(forKey: lastPlayedOriginKey) else { return nil }
            return try? JSONDecoder().decode(PlaybackOrigin.self, from: data)
        }
        set {
            defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: lastPlayedOriginKey)
        }
    }

    static var queue: [ItemIdentifier] {
        get { (defaults.stringArray(forKey: queueKey) ?? []).compactMap(ItemIdentifier.init) }
        set { defaults.set(newValue.map(\.description), forKey: queueKey) }
    }
}
