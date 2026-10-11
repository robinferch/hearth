import AppIntents
import CoreSpotlight
import HearthData
import HearthIntents
import HearthModel
import HearthPlayback
import OSLog
import SwiftUI

/// Starts the system integrations: App Intents routing, Siri donations, the sleep timer Live Activity,
/// Spotlight indexing and the Listen Now snapshot. Call `start()` from `didFinishLaunching`.
@MainActor
final class SystemIntegration {
    static let shared = SystemIntegration()

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hearth", category: "SystemIntegration")
    private var didStart = false
    private var tokens: [any NSObjectProtocol] = []

    private init() {}

    func start() {
        guard !didStart else { return }
        didStart = true

        // Must be registered before launch finishes.
        SpotlightIndexer.shared.registerBackgroundTask()

        IntentNavigator.handler = { route in
            switch route {
            case .open(let id): AppEvents.shared.post(.open(id))
            case .search(let query): AppEvents.shared.post(.search(query))
            }
        }
        if let pending = IntentNavigator.consumePending() {
            IntentNavigator.handler?(pending)
        }

        SiriDonations.shared.start()
        LiveActivityController.shared.start()

        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: AudioPlayer.itemFinishedNotification, object: nil, queue: .main) { _ in
            // The finished item leaves Listen Now; widgets should follow promptly.
            Task { @MainActor in await HearthData.shared.updateListenNowSnapshot() }
        })

        #if DEBUG
        DebugLogin.runIfRequested()
        #endif

        Task {
            await HearthData.shared.bootstrap()
            await SpotlightIndexer.shared.launchUpdate()
        }
    }
}

/// Includes the shared HearthIntents types in the app's App Intents metadata.
struct HearthAppIntentsPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] {
        [HearthIntentsPackage.self]
    }
}

// MARK: - Scene hooks

extension View {
    /// Spotlight result taps and "search in app" continuation. Apply to each window's root view.
    func systemIntegrationHandlers() -> some View {
        self
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                if let string = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String, let id = ItemIdentifier(string) {
                    AppEvents.shared.post(.open(id))
                }
            }
            .onContinueUserActivity(CSQueryContinuationActionType) { activity in
                let query = activity.userInfo?[CSSearchQueryString] as? String
                AppEvents.shared.post(.search(query))
            }
    }
}
