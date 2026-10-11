import HearthData
import HearthPlayback
import HearthUI
import SwiftUI
import WatchKit

@main
struct HearthWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .tint(AppSettings.shared.tintColor.color)
        }
        .onChange(of: scenePhase) { _, phase in
            WatchLifecycle.shared.scenePhaseChanged(phase)
        }
    }
}

/// Launch + background tasks (download sessions, WatchConnectivity wake-ups).
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        WatchLifecycle.shared.launch()
    }

    func applicationWillResignActive() {
        PhoneLink.shared.checkTokens()
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            switch task {
            case let urlTask as WKURLSessionRefreshBackgroundTask:
                HearthData.shared.downloads.handleBackgroundEvents(identifier: urlTask.sessionIdentifier) {
                    DispatchQueue.main.async {
                        task.setTaskCompletedWithSnapshot(false)
                    }
                }
            case is WKWatchConnectivityRefreshBackgroundTask:
                // Pending messages are delivered once the session is active; give it a moment.
                WatchLifecycle.shared.launch()
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    task.setTaskCompletedWithSnapshot(false)
                }
            default:
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}

/// App-wide lifecycle: bootstrap, phone link, foreground refresh.
@MainActor
@Observable
final class WatchLifecycle {
    static let shared = WatchLifecycle()

    private(set) var isBootstrapped = false
    @ObservationIgnored private var didLaunch = false
    @ObservationIgnored private var lastRefresh = Date.now

    private init() {}

    func launch() {
        guard !didLaunch else { return }
        didLaunch = true
        AudioPlayer.shared.setup()
        PhoneLink.shared.activate()
        Task {
            #if DEBUG
            await DebugLogin.runIfRequested()
            #endif
            await HearthData.shared.bootstrap()
            isBootstrapped = true
            lastRefresh = .now
            #if DEBUG
            await DebugLogin.runActions()
            #endif
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard phase == .active else { return }
        launch()
        Task { await PhoneLink.shared.refresh() }
        guard isBootstrapped, Date.now.timeIntervalSince(lastRefresh) > 5 * 60 else { return }
        lastRefresh = .now
        Task { await HearthData.shared.refresh() }
    }
}
