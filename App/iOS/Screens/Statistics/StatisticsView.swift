import Charts
import HearthAPI
import HearthData
import HearthModel
import HearthUI
import SwiftUI

/// Listening statistics of a connection: today vs goal, last 7 / 30 days, total, streak and top items.
struct StatisticsView: View {
    let connectionID: ConnectionID

    @State private var state: LoadState<ListeningStats> = .loading
    @State private var range: ChartRange = .week

    enum ChartRange: Int, CaseIterable, Identifiable {
        case week = 7
        case month = 30

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .week: String(localized: "7 Days")
            case .month: String(localized: "30 Days")
            }
        }
    }

    var body: some View {
        LoadStateView(state, retry: load) { stats in
            ScrollView {
                VStack(spacing: 16) {
                    TodayCard(stats: stats)
                    ChartCard(stats: stats, range: $range)
                    HStack(spacing: 16) {
                        StatTile(title: String(localized: "Total Time"), value: HearthFormat.totalTime(stats.totalTime), systemImage: "clock")
                        StatTile(title: String(localized: "Streak"), value: String(localized: "\(Self.streak(in: stats)) days"), systemImage: "flame")
                    }
                    if !stats.topItems.isEmpty {
                        TopItemsCard(items: stats.topItems)
                    }
                }
                .padding(20)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
        }
        .navigationTitle("Statistics")
        .refreshable { await load() }
        .task(id: connectionID) { await load() }
    }

    private func load() async {
        do {
            state = .loaded(try await HearthData.shared.listening.stats(connection: connectionID))
        } catch {
            if state.value == nil {
                state = .failed(error)
            }
        }
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func seconds(on date: Date, in stats: ListeningStats) -> TimeInterval {
        stats.days[dayFormatter.string(from: date)] ?? 0
    }

    /// Consecutive days with at least one minute listened, ending today (or yesterday if today is empty).
    static func streak(in stats: ListeningStats, now: Date = .now) -> Int {
        let calendar = Calendar.current
        func listened(_ day: Date) -> TimeInterval {
            calendar.isDateInToday(day) ? max(seconds(on: day, in: stats), stats.today) : seconds(on: day, in: stats)
        }
        var day = calendar.startOfDay(for: now)
        if listened(day) < 60, let yesterday = calendar.date(byAdding: .day, value: -1, to: day) {
            day = yesterday
        }
        var count = 0
        while listened(day) >= 60 {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }
}

private struct TodayCard: View {
    let stats: ListeningStats

    private var settings: AppSettings { .shared }

    var body: some View {
        let today = max(stats.today, HearthData.shared.listening.listenedToday)
        let goal = settings.dailyGoalMinutes
        let minutes = Int(today / 60)
        HStack(spacing: 20) {
            ZStack {
                ProgressRing(progress: goal > 0 ? Double(minutes) / Double(goal) : 0, lineWidth: 12)
                VStack(spacing: 0) {
                    Text(minutes, format: .number)
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .contentTransition(.numericText(value: Double(minutes)))
                    Text("min")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 110, height: 110)
            VStack(alignment: .leading, spacing: 6) {
                Text("Today")
                    .font(.headline)
                Text(minutes >= goal ? String(localized: "Daily goal reached. Well done!") : String(localized: "\(max(goal - minutes, 0)) min left to reach your goal of \(goal) min."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Stepper("Goal: \(goal) min", value: Bindable(settings).dailyGoalMinutes, in: 5...600, step: 5)
                    .font(.subheadline)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: .rect(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

private struct ChartCard: View {
    let stats: ListeningStats
    @Binding var range: StatisticsView.ChartRange

    private struct DayValue: Identifiable {
        let date: Date
        let minutes: Double
        var id: Date { date }
    }

    private var values: [DayValue] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        return (0..<range.rawValue).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return DayValue(date: date, minutes: StatisticsView.seconds(on: date, in: stats) / 60)
        }
    }

    var body: some View {
        let values = values
        let goal = Double(AppSettings.shared.dailyGoalMinutes)
        let average = values.isEmpty ? 0 : values.map(\.minutes).reduce(0, +) / Double(values.count)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Daily Average")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(HearthFormat.minutes(average * 60))
                        .font(.title2.weight(.semibold))
                }
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(StatisticsView.ChartRange.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            Chart {
                ForEach(values) { value in
                    BarMark(
                        x: .value("Day", value.date, unit: .day),
                        y: .value("Minutes", value.minutes)
                    )
                    .foregroundStyle(value.minutes >= goal ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.45)))
                    .clipShape(.rect(cornerRadius: 4))
                }
                RuleMark(y: .value("Goal", goal))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, alignment: .leading) {
                        Text("Goal")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: range == .week ? 1 : 7)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: range == .week ? .dateTime.weekday(.narrow) : .dateTime.day().month(.abbreviated))
                }
            }
            .chartYAxisLabel("min")
            .frame(height: 200)
            .animation(.smooth, value: range)
        }
        .padding(20)
        .background(.background, in: .rect(cornerRadius: 20, style: .continuous))
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: .rect(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct TopItemsCard: View {
    let items: [ListeningStats.TopItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Most Listened")
                .font(.headline)
            let maximum = items.map(\.timeListening).max() ?? 1
            ForEach(Array(items.prefix(10).enumerated()), id: \.element.id) { index, item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(index + 1).")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(item.title)
                            .lineLimit(1)
                        Spacer()
                        Text(HearthFormat.totalTime(item.timeListening))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                    ProgressCapsule(progress: item.timeListening / max(maximum, 1), height: 4)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: .rect(cornerRadius: 20, style: .continuous))
    }
}
