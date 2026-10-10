import HearthData
import HearthModel
import HearthUI
import SwiftUI

/// In-progress items across all libraries. As a sheet, tapping an item plays it and dismisses.
struct ListenNowView: View {
    static let transitionID = "listen-now"

    /// Presented as a sheet (adds Done, tap plays & dismisses) vs. iPad sidebar tab (tap opens).
    var isSheet = true

    @Environment(\.dismiss) private var dismiss
    @Environment(\.itemActionHandler) private var handler

    @State private var state: LoadState<[AnyPlayableItem]> = .loading

    private var settings: AppSettings { .shared }

    var body: some View {
        List {
            Section {
                ListenedTodayHeader()
            }
            switch state {
            case .loading:
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            case .failed(let error):
                Section {
                    Text(error.userMessage)
                        .foregroundStyle(.secondary)
                }
            case .loaded(let items):
                Section {
                    if items.isEmpty {
                        Text("Nothing in progress. Start listening and your books and episodes show up here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(items) { item in
                        row(for: item)
                    }
                } header: {
                    Text("In Progress")
                }
            }
            Section {
                Toggle(isOn: Bindable(settings).autoDownloadListenNow) {
                    Label("Auto-Download Listen Now", systemImage: "arrow.down.circle")
                }
            } footer: {
                Text("Keeps the items in Listen Now downloaded so you can listen offline.")
            }
        }
        .navigationTitle("Listen Now")
        .toolbar {
            if isSheet {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .onChange(of: settings.autoDownloadListenNow) { _, enabled in
            if enabled {
                Task { await HearthData.shared.downloads.runAutoDownloads() }
            }
        }
    }

    @ViewBuilder
    private func row(for item: AnyPlayableItem) -> some View {
        if isSheet {
            Button {
                Task {
                    await handler.play(item.id)
                    dismiss()
                }
            } label: {
                CompactItemRow(item: item)
            }
            .buttonStyle(.plain)
            .itemActions(for: item, context: .listenNow)
        } else {
            NavigationLink(value: NavigationDestination.item(item.id)) {
                CompactItemRow(item: item)
            }
            .itemActions(for: item, context: .listenNow)
        }
    }

    private func load() async {
        let items = await HearthData.shared.items.listenNow()
        state = .loaded(items)
    }
}

/// Large listened-today gauge with goal stepper.
struct ListenedTodayHeader: View {
    private var settings: AppSettings { .shared }

    var body: some View {
        let listened = HearthData.shared.listening.listenedToday
        HStack(spacing: 16) {
            ListenedTodayGauge(listened: listened, goalMinutes: settings.dailyGoalMinutes, lineWidth: 6)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text("Listened Today")
                    .font(.headline)
                Text("\(Int(listened / 60)) of \(settings.dailyGoalMinutes) min")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Stepper("Daily Goal", value: Bindable(settings).dailyGoalMinutes, in: 5...600, step: 5)
                .labelsHidden()
        }
        .padding(.vertical, 4)
    }
}

/// iPad sidebar header row: "Listened today" gauge + minutes.
struct ListenedTodaySidebarRow: View {
    @Environment(Navigator.self) private var navigator

    private var settings: AppSettings { .shared }

    var body: some View {
        let listened = HearthData.shared.listening.listenedToday
        Button {
            navigator.sheet = .listenNow
        } label: {
            HStack(spacing: 12) {
                ListenedTodayGauge(listened: listened, goalMinutes: settings.dailyGoalMinutes, lineWidth: 3)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Listened Today")
                        .font(.subheadline.weight(.semibold))
                    Text("\(Int(listened / 60)) of \(settings.dailyGoalMinutes) min")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .hoverEffect(.highlight)
    }
}
