import SwiftUI
import WidgetKit

@main
struct HearthWidgetsBundle: WidgetBundle {
    var body: some Widget {
        PlaceholderWidget()
    }
}

struct PlaceholderWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "placeholder", provider: Provider()) { _ in Text("Hearth") }
    }

    struct Provider: TimelineProvider {
        func placeholder(in context: Context) -> Entry { Entry(date: .now) }
        func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry(date: .now)) }
        func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) { completion(Timeline(entries: [Entry(date: .now)], policy: .never)) }
    }

    struct Entry: TimelineEntry { let date: Date }
}
