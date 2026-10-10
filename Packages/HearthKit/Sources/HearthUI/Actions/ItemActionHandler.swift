import Foundation
import HearthAPI
import HearthData
import HearthModel
import SwiftUI

/// Actions that shared components trigger but cannot perform themselves (HearthUI does not depend on
/// HearthPlayback). The app injects an implementation with `.environment(\.itemActionHandler, …)`.
///
/// The default value performs data-only actions (downloads, progress) directly against HearthData and
/// hides playback actions (`canPlay == false`), which suits widgets and previews.
public struct ItemActionHandler: Sendable {
    public typealias ItemAction = @MainActor @Sendable (ItemIdentifier) async -> Void

    /// Whether playback actions are available (false in widgets / previews).
    public var canPlay: Bool
    /// Starts the item (toggles play/pause if it is already current).
    public var play: ItemAction
    /// Starts the first eligible item of a series / podcast / collection.
    public var playGrouping: ItemAction
    public var playNext: ItemAction
    public var addToQueue: ItemAction
    public var setFinished: @MainActor @Sendable (ItemIdentifier, Bool) async -> Void
    public var resetProgress: ItemAction
    public var hideFromContinueListening: ItemAction
    public var download: ItemAction
    public var removeDownload: ItemAction
    public var cancelDownload: ItemAction
    /// Presents the "Add to…" (collections & playlists) sheet.
    public var addTo: @MainActor @Sendable (ItemIdentifier) -> Void
    /// Pushes a destination onto the current navigation stack.
    public var navigate: @MainActor @Sendable (NavigationDestination) -> Void
    /// Opens the item in a new window (iPad), if supported.
    public var openInNewWindow: (@MainActor @Sendable (ItemIdentifier) -> Void)?
    /// Whether `id` is the player's current item.
    public var isCurrent: @MainActor @Sendable (ItemIdentifier) -> Bool
    /// Whether `id` is current and playing.
    public var isPlaying: @MainActor @Sendable (ItemIdentifier) -> Bool
    /// Web page of the item for sharing.
    public var shareURL: @MainActor @Sendable (ItemIdentifier) -> URL?

    public init(
        canPlay: Bool = false,
        play: @escaping ItemAction = { _ in },
        playGrouping: @escaping ItemAction = { _ in },
        playNext: @escaping ItemAction = { _ in },
        addToQueue: @escaping ItemAction = { _ in },
        setFinished: @escaping @MainActor @Sendable (ItemIdentifier, Bool) async -> Void = { id, finished in
            try? await HearthData.shared.progress.setFinished(id, finished: finished)
        },
        resetProgress: @escaping ItemAction = { id in try? await HearthData.shared.progress.reset(id) },
        hideFromContinueListening: @escaping ItemAction = { id in try? await HearthData.shared.progress.hideFromContinueListening(id) },
        download: @escaping ItemAction = { id in try? await HearthData.shared.downloads.download(id) },
        removeDownload: @escaping ItemAction = { id in await HearthData.shared.downloads.remove(id) },
        cancelDownload: @escaping ItemAction = { id in await HearthData.shared.downloads.cancel(id) },
        addTo: @escaping @MainActor @Sendable (ItemIdentifier) -> Void = { _ in },
        navigate: @escaping @MainActor @Sendable (NavigationDestination) -> Void = { _ in },
        openInNewWindow: (@MainActor @Sendable (ItemIdentifier) -> Void)? = nil,
        isCurrent: @escaping @MainActor @Sendable (ItemIdentifier) -> Bool = { _ in false },
        isPlaying: @escaping @MainActor @Sendable (ItemIdentifier) -> Bool = { _ in false },
        shareURL: @escaping @MainActor @Sendable (ItemIdentifier) -> URL? = { id in
            (try? HearthData.shared.connections.client(for: id.connectionID))?.webURL(for: id)
        }
    ) {
        self.canPlay = canPlay
        self.play = play
        self.playGrouping = playGrouping
        self.playNext = playNext
        self.addToQueue = addToQueue
        self.setFinished = setFinished
        self.resetProgress = resetProgress
        self.hideFromContinueListening = hideFromContinueListening
        self.download = download
        self.removeDownload = removeDownload
        self.cancelDownload = cancelDownload
        self.addTo = addTo
        self.navigate = navigate
        self.openInNewWindow = openInNewWindow
        self.isCurrent = isCurrent
        self.isPlaying = isPlaying
        self.shareURL = shareURL
    }
}

public extension EnvironmentValues {
    /// Item actions used by rows, context menus, swipe actions and play buttons.
    @Entry var itemActionHandler = ItemActionHandler()
}
