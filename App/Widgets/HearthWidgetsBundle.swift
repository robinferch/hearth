import AppIntents
import HearthIntents
import SwiftUI
import WidgetKit

@main
struct HearthWidgetsBundle: WidgetBundle {
    var body: some Widget {
        PlayWidget()
        ListenNowWidget()
        ListenedTodayWidget()
        SleepTimerLiveActivity()
        PlayPauseControl()
        SkipBackwardControl()
        SkipForwardControl()
        SleepTimerControl()
        SearchControl()
    }
}

/// Includes the shared HearthIntents types (entities, intents used by buttons and controls) in this extension's
/// App Intents metadata.
struct HearthWidgetsIntentsPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] {
        [HearthIntentsPackage.self]
    }
}
