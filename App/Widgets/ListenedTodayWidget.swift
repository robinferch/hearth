import HearthData
import HearthModel
import HearthUI
import SwiftUI
import WidgetKit

struct ListenedTodayEntry: TimelineEntry {
    let date: Date
    let listened: TimeInterval
    let goalMinutes: Int
    let tint: TintColor

    var minutes: Int { Int(listened / 60) }
    var fraction: Double { goalMinutes > 0 ? min(Double(minutes) / Double(goalMinutes), 1) : 0 }
}

struct ListenedTodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> ListenedTodayEntry {
        ListenedTodayEntry(date: .now, listened: 18 * 60, goalMinutes: 30, tint: .hearth)
    }

    func getSnapshot(in context: Context, completion: @escaping (ListenedTodayEntry) -> Void) {
        completion(entry(at: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ListenedTodayEntry>) -> Void) {
        let now = Date.now
        var entries = [entry(at: now)]
        // Reset at midnight even if the app doesn't run.
        if let midnight = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime) {
            let snapshot = WidgetData.snapshot()
            entries.append(ListenedTodayEntry(date: midnight, listened: 0, goalMinutes: snapshot.dailyGoalMinutes, tint: snapshot.tint))
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private func entry(at date: Date) -> ListenedTodayEntry {
        let snapshot = WidgetData.snapshot()
        return ListenedTodayEntry(date: date, listened: WidgetData.listenedToday(snapshot, at: date), goalMinutes: max(1, snapshot.dailyGoalMinutes), tint: snapshot.tint)
    }
}

struct ListenedTodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.listenedToday, provider: ListenedTodayProvider()) { entry in
            ListenedTodayWidgetView(entry: entry)
                .widgetTint(entry.tint)
                .hearthWidgetBackground()
                .widgetURL(WidgetData.url(host: "statistics"))
        }
        .configurationDisplayName("Listened Today")
        .description("Your listening time today and your daily goal.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

struct ListenedTodayWidgetView: View {
    let entry: ListenedTodayEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: Double(min(entry.minutes, entry.goalMinutes)), in: 0...Double(entry.goalMinutes)) {
                Image(systemName: "headphones")
            } currentValueLabel: {
                Text(entry.minutes, format: .number)
            }
            .gaugeStyle(.accessoryCircular)
            .widgetAccentable()
            .accessibilityLabel(Text("Listened Today"))
            .accessibilityValue(Text("\(entry.minutes) of \(entry.goalMinutes) minutes"))
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label("Listened Today", systemImage: "headphones")
                    .font(.headline)
                    .widgetAccentable()
                Text("\(entry.minutes) of \(entry.goalMinutes) min")
                    .font(.caption)
                Gauge(value: entry.fraction) {
                    EmptyView()
                }
                .gaugeStyle(.accessoryLinearCapacity)
                .widgetAccentable()
            }
        default:
            small
        }
    }

    private var small: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Today")
                    .font(.headline)
                    .foregroundStyle(.tint)
                Spacer()
                if entry.fraction >= 1 {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.tint)
                        .accessibilityLabel(Text("Goal reached"))
                }
            }
            ListenedTodayGauge(listened: entry.listened, goalMinutes: entry.goalMinutes, lineWidth: 9)
                .frame(maxHeight: .infinity)
            Text("\(entry.minutes) of \(entry.goalMinutes) min")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
