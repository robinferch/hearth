import HearthData
import HearthModel
import HearthPlayback
import HearthUI
import SwiftUI

@main
struct HearthApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .systemIntegrationHandlers()
        }
        .commands {
            HearthCommands()
        }
        .backgroundTask(.appRefresh(BackgroundTaskScheduler.autoDownloadIdentifier)) {
            await BackgroundTaskScheduler.runAutoDownloads()
        }
        .backgroundTask(.appRefresh(BackgroundTaskScheduler.syncIdentifier)) {
            await BackgroundTaskScheduler.runSync()
        }
        .onChange(of: scenePhase) { _, phase in
            AppLifecycle.shared.scenePhaseChanged(phase)
        }

        // Opens an item in its own window (iPad): `openWindow(value: ItemIdentifier)`.
        WindowGroup(id: "item", for: ItemIdentifier.self) { $id in
            ItemWindowView(id: id)
        }
    }
}

/// A secondary window showing a single item (iPad multi-window).
struct ItemWindowView: View {
    let id: ItemIdentifier?

    @State private var navigator = Navigator()
    @State private var alerts = AlertCenter()
    @State private var player = PlayerPresentation()

    var body: some View {
        NavigationStack(path: navigator.path(for: .noLibrary)) {
            Group {
                if let id {
                    ItemDestinationView(id: id)
                } else {
                    EmptyStateView(title: String(localized: "Item Unavailable"), systemImage: "questionmark.square.dashed")
                }
            }
            .hearthNavigationDestinations()
        }
        .onAppear {
            navigator.selectedTab = .noLibrary
        }
        // Like the main window: scene sheets (Add to…), the full player and (via the scene environment) alerts
        // and the bookmark prompt.
        .sceneSheets(navigator: navigator, alerts: alerts, player: player, handler: handler)
        .fullScreenCover(isPresented: $player.isExpanded) {
            NowPlayingView()
                .sceneAlertHost()
        }
        .sensoryFeedback(.success, trigger: alerts.successTrigger)
        .sensoryFeedback(.error, trigger: alerts.errorTrigger)
        .hearthSceneEnvironment(navigator: navigator, alerts: alerts, player: player, handler: handler)
        .focusedSceneValue(\.navigator, navigator)
    }

    private var handler: ItemActionHandler {
        AppItemActions.handler(navigator: navigator, alerts: alerts, player: player, openWindow: nil)
    }
}
