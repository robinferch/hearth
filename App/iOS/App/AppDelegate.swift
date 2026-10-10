import HearthData
import HearthModel
import HearthPlayback
import OSLog
import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hearth", category: "AppDelegate")

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AppLifecycle.shared.launch()
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        AudioPlayer.shared.appWillTerminate()
    }

    /// Background download session events (`<bundle>.downloads`).
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        nonisolated(unsafe) let completion = completionHandler
        HearthData.shared.downloads.handleBackgroundEvents(identifier: identifier) {
            DispatchQueue.main.async {
                completion()
            }
        }
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if connectingSceneSession.role == .carTemplateApplication {
            return UISceneConfiguration(name: "CarPlay", sessionRole: connectingSceneSession.role)
        }
        if let shortcut = options.shortcutItem {
            _ = QuickActions.handle(shortcut)
        }
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

/// Receives home-screen quick actions while the app is running.
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem) async -> Bool {
        QuickActions.handle(shortcutItem)
    }
}

/// App-wide lifecycle: bootstrap, foreground refresh, live updates, background scheduling.
@MainActor
final class AppLifecycle {
    static let shared = AppLifecycle()

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hearth", category: "AppLifecycle")
    private var didLaunch = false
    private var lastRefresh: Date?

    private init() {}

    /// Called once from `didFinishLaunching`.
    func launch() {
        guard !didLaunch else { return }
        didLaunch = true
        AudioPlayer.shared.setup()
        Task {
            await HearthData.shared.bootstrap()
            AppEvents.shared.bootstrapFinished = true
            Self.logger.info("Bootstrap finished with \(HearthData.shared.connections.connections.count) connection(s)")
            await startLiveUpdates()
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            Task {
                // Avoid double refreshes right after launch / quick app switches.
                if let lastRefresh, Date.now.timeIntervalSince(lastRefresh) < 30 {
                    return
                }
                lastRefresh = .now
                if AppEvents.shared.bootstrapFinished {
                    await HearthData.shared.refresh()
                }
                await HearthData.shared.listening.refresh()
                await startLiveUpdates()
            }
        case .background:
            AudioPlayer.shared.appDidEnterBackground()
            BackgroundTaskScheduler.scheduleAll()
            QuickActions.update()
            Task { await HearthData.shared.updateListenNowSnapshot() }
            Task { await stopLiveUpdates() }
        default:
            break
        }
    }

    /// Socket.IO live updates (foreground only).
    func startLiveUpdates() async {
        HearthData.shared.startLiveUpdates()
    }

    func stopLiveUpdates() async {
        HearthData.shared.stopLiveUpdates()
    }
}

extension Notification.Name {
    /// Posted when the device is shaken (see `UIWindow.motionEnded`).
    static let deviceDidShake = Notification.Name("HearthDeviceDidShake")
}

extension UIWindow {
    override open func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShake, object: nil)
        }
        super.motionEnded(motion, with: event)
    }
}
