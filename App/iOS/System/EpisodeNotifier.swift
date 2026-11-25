import HearthAPI
import HearthData
import HearthModel
import HearthPlayback
import HearthUI
import OSLog
import UIKit
import UserNotifications

/// Notifications about new podcast episodes.
///
/// audiobookshelf can't push to third-party apps, so Hearth checks the podcast libraries itself: during background
/// app refresh (iOS decides when) and when the server reports a new item while the app runs. The first check after
/// enabling only records what exists.
@MainActor
final class EpisodeNotifier: NSObject {
    static let shared = EpisodeNotifier()

    nonisolated static let categoryIdentifier = "NEW_EPISODE"
    private nonisolated static let playAction = "PLAY"
    private nonisolated static let downloadAction = "DOWNLOAD"
    private nonisolated static let itemKey = "itemID"
    /// More new episodes than this in one check are summarized in one notification.
    private static let individualLimit = 4

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hearth", category: "EpisodeNotifier")

    private let center = UNUserNotificationCenter.current()
    private let tracker = NewEpisodeTracker()
    private var isChecking = false
    private var pendingCheck: Task<Void, Never>?

    private override init() {}

    /// Call from `didFinishLaunching` (the delegate must be set before launch finishes to receive taps).
    func start() {
        center.delegate = self
        let play = UNNotificationAction(identifier: Self.playAction, title: String(localized: "Play", table: "Notifications"), options: [.foreground], icon: UNNotificationActionIcon(systemImageName: "play.fill"))
        let download = UNNotificationAction(identifier: Self.downloadAction, title: String(localized: "Download", table: "Notifications"), options: [], icon: UNNotificationActionIcon(systemImageName: "arrow.down.circle"))
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryIdentifier, actions: [play, download], intentIdentifiers: [], options: []),
        ])
        HearthData.shared.itemAddedHandler = { [weak self] library in
            guard HearthData.shared.connections.library(library)?.mediaType == .podcasts else { return }
            self?.scheduleCheck()
        }
    }

    // MARK: Permission

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// Turns notifications on (asks for permission). Returns `false` when permission was denied.
    func enable() async -> Bool {
        let granted: Bool
        switch await authorizationStatus() {
        case .authorized, .provisional, .ephemeral:
            granted = true
        case .notDetermined:
            granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default:
            granted = false
        }
        guard granted else {
            AppSettings.shared.newEpisodeNotifications = false
            return false
        }
        AppSettings.shared.newEpisodeNotifications = true
        tracker.reset()
        // Baseline: what exists now isn't new.
        await check()
        BackgroundTaskScheduler.scheduleAll()
        return true
    }

    func disable() {
        AppSettings.shared.newEpisodeNotifications = false
    }

    // MARK: Checking

    /// Debounced check (several items can be added at once).
    func scheduleCheck() {
        pendingCheck?.cancel()
        pendingCheck = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await check()
        }
    }

    /// Looks for new episodes in all podcast libraries and notifies about them.
    func check() async {
        guard AppSettings.shared.newEpisodeNotifications, !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        let status = await authorizationStatus()
        guard status == .authorized || status == .provisional else { return }

        let connections = HearthData.shared.connections
        if connections.allLibraries.isEmpty {
            await connections.reloadLibraries()
        }
        var found: [Episode] = []
        for library in connections.allLibraries where library.mediaType == .podcasts && connections.isAvailable(library.id.connectionID) {
            guard let client = try? connections.client(for: library.id.connectionID) else { continue }
            do {
                let episodes = try await client.recentEpisodes(library: library.id, limit: 30)
                found += tracker.register(episodes, in: library.id)
            } catch {
                Self.logger.notice("Checking \(library.name, privacy: .private) for new episodes failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let settings = AppSettings.shared
        let new = found.filter { episode in
            episode.id.podcastIdentifier.map(settings.notificationsEnabled(for:)) ?? true
        }
        guard !new.isEmpty else { return }
        Self.logger.info("Found \(new.count) new episode(s)")
        if new.count > Self.individualLimit {
            await postSummary(new)
        } else {
            for episode in new {
                await post(episode)
            }
        }
    }

    private func post(_ episode: Episode) async {
        let content = UNMutableNotificationContent()
        content.title = episode.podcastName
        content.body = episode.name
        if episode.duration > 0 {
            content.subtitle = HearthFormat.duration(episode.duration)
        }
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.threadIdentifier = episode.id.podcastIdentifier?.description ?? episode.podcastName
        content.targetContentIdentifier = episode.id.description
        content.userInfo = [Self.itemKey: episode.id.description]
        if let attachment = await coverAttachment(for: episode) {
            content.attachments = [attachment]
        }
        let request = UNNotificationRequest(identifier: "episode-\(episode.id.description)", content: content, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            Self.logger.error("Posting a notification failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func postSummary(_ episodes: [Episode]) async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(episodes.count) New Episodes", table: "Notifications")
        let podcasts = Array(NSOrderedSet(array: episodes.map(\.podcastName))) as? [String] ?? []
        content.body = podcasts.prefix(4).joined(separator: ", ") + (podcasts.count > 4 ? " …" : "")
        content.sound = .default
        content.threadIdentifier = "new-episodes"
        let request = UNNotificationRequest(identifier: "episodes-\(UUID().uuidString)", content: content, trigger: nil)
        try? await center.add(request)
    }

    /// The cover as a notification thumbnail (copied, the system moves attachment files).
    private func coverAttachment(for episode: Episode) async -> UNNotificationAttachment? {
        guard let data = await HearthData.shared.images.imageData(for: episode.id, size: .small) else { return nil }
        let url = FileManager.default.temporaryDirectory.appending(path: "notification-cover-\(UUID().uuidString).jpg")
        do {
            try data.write(to: url)
            return try UNNotificationAttachment(identifier: "cover", url: url, options: [UNNotificationAttachmentOptionsTypeHintKey: "public.jpeg"])
        } catch {
            return nil
        }
    }

    // MARK: Responses

    private func handle(actionIdentifier: String, itemID: ItemIdentifier?) async {
        guard let itemID else { return }
        switch actionIdentifier {
        case Self.playAction:
            AppEvents.shared.post(.play(itemID))
        case Self.downloadAction:
            if !AppEvents.shared.bootstrapFinished {
                await HearthData.shared.bootstrap()
            }
            try? await HearthData.shared.downloads.download(itemID)
        default:
            AppEvents.shared.post(.open(itemID))
        }
    }
}

extension EpisodeNotifier: UNUserNotificationCenterDelegate {
    // Called on an arbitrary queue: nonisolated, hopping to the main actor (see the WatchSyncSession crash).

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let id = (response.notification.request.content.userInfo[Self.itemKey] as? String).flatMap(ItemIdentifier.init)
        await handle(actionIdentifier: action, itemID: id)
    }
}
