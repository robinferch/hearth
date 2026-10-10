import HearthData
import HearthModel
import UIKit

/// Home-screen quick actions: Search (static, Info.plist) + up to 3 Listen Now items that play directly.
@MainActor
enum QuickActions {
    private static let playType = "play"
    private static let searchType = "search"
    private static let itemKey = "itemID"

    static func handle(_ item: UIApplicationShortcutItem) -> Bool {
        switch item.type {
        case searchType:
            AppEvents.shared.post(.search(nil))
            return true
        case playType:
            guard let string = item.userInfo?[itemKey] as? String, let id = ItemIdentifier(string) else { return false }
            AppEvents.shared.post(.play(id))
            return true
        default:
            return false
        }
    }

    /// Refreshes the dynamic shortcut items from Listen Now (called when entering the background).
    static func update() {
        Task {
            let items = await HearthData.shared.items.listenNow().prefix(3)
            UIApplication.shared.shortcutItems = items.map { item in
                UIApplicationShortcutItem(
                    type: playType,
                    localizedTitle: item.name,
                    localizedSubtitle: item.base.subtitleLine ?? item.base.authorLine,
                    icon: UIApplicationShortcutIcon(systemImageName: "play.fill"),
                    userInfo: [itemKey: item.id.description as NSString]
                )
            }
        }
    }
}
