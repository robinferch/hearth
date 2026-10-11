import SwiftUI
import WidgetKit

@main
struct HearthWatchWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingComplication()
        ListenedTodayComplication()
    }
}
