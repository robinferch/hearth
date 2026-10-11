import HearthData
import HearthUI
import SwiftUI
import WidgetKit

/// Minutes listened today against the daily goal.
struct ListenedTodayComplication: Widget {
    static let kind = "dev.hearth.watch.listenedToday"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider(relevance: ListenedTodayRelevance.score)) { entry in
            ListenedTodayComplicationView(entry: entry)
                .containerBackground(entry.tint.gradient.opacity(0.35), for: .widget)
                .widgetURL(URL(string: "hearth://home"))
        }
        .configurationDisplayName("Listened Today")
        .description("Your listening time today and your daily goal.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryCorner, .accessoryInline])
    }
}

enum ListenedTodayRelevance {
    /// Slightly relevant in the evening while the goal isn't reached.
    static func score(for snapshot: SharedSnapshot, at date: Date) -> Float {
        let minutes = Calendar.current.isDate(snapshot.updatedAt, inSameDayAs: date) ? Int(snapshot.listenedToday / 60) : 0
        guard minutes < snapshot.dailyGoalMinutes else { return 0 }
        let hour = Calendar.current.component(.hour, from: date)
        return hour >= 18 ? 30 : 5
    }
}

struct ListenedTodayComplicationView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    private var minutes: Int { entry.listenedMinutes }
    private var goal: Int { entry.goalMinutes }
    private var fraction: Double { min(1, Double(minutes) / Double(goal)) }

    var body: some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Listened today")
            .accessibilityValue(Text("\(minutes) of \(goal) minutes"))
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: Double(min(minutes, goal)), in: 0...Double(goal)) {
                Image(systemName: "headphones")
            } currentValueLabel: {
                Text(minutes, format: .number)
                    .monospacedDigit()
            }
            .gaugeStyle(.accessoryCircular)
            .tint(entry.tint)
        case .accessoryCorner:
            Text("\(minutes)m")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .widgetCurvesContent()
                .widgetLabel {
                    Gauge(value: Double(min(minutes, goal)), in: 0...Double(goal)) {
                        Text("Today")
                    }
                    .tint(entry.tint)
                }
        case .accessoryInline:
            Label("\(minutes) of \(goal) min today", systemImage: "headphones")
        default:
            VStack(alignment: .leading, spacing: 3) {
                Label("Listened Today", systemImage: "headphones")
                    .font(.caption2)
                    .foregroundStyle(entry.tint)
                    .widgetAccentable()
                Text("\(minutes) of \(goal) min")
                    .font(.headline)
                    .monospacedDigit()
                Gauge(value: fraction) {
                    EmptyView()
                }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(entry.tint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview("Circular", as: .accessoryCircular) {
    ListenedTodayComplication()
} timeline: {
    SnapshotEntry.preview
}

#Preview("Rectangular", as: .accessoryRectangular) {
    ListenedTodayComplication()
} timeline: {
    SnapshotEntry.preview
}
