import HearthData
import HearthModel
import HearthUI
import SwiftUI

/// Per-item / per-grouping playback configuration (audiobook, series, podcast, collection, playlist):
/// playback speed, automatic sleep timer, Up Next strategy, suggestions and the automatic download rule.
/// Values differing from the defaults are shown in bold.
struct ConfigureSheet: View {
    let id: ItemIdentifier
    let title: String

    @Environment(\.dismiss) private var dismiss

    @State private var rate: Double?
    @State private var sleepTimer: SleepTimerPreset?
    @State private var upNext: UpNextStrategy = .default
    @State private var allowsSuggestions = true
    @State private var autoDownload: AutoDownloadRule = .disabled

    private var data: HearthData { .shared }
    private var settings: AppSettings { .shared }

    private var supportsUpNext: Bool { id.kind == .series || id.kind == .podcast }
    private var supportsAutoDownload: Bool { id.kind == .series || id.kind == .podcast }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    rateRow
                    sleepTimerRow
                } header: {
                    Text("Playback", tableName: "Detail")
                } footer: {
                    Text(id.kind == .audiobook ? String(localized: "Applies whenever this audiobook is played.", table: "Detail") : String(localized: "Applies to items started from here unless they have their own settings.", table: "Detail"))
                }

                if supportsUpNext {
                    Section {
                        Picker(selection: $upNext) {
                            ForEach(UpNextStrategy.allCases, id: \.self) { strategy in
                                Text(strategy.configureTitle).tag(strategy)
                            }
                        } label: {
                            Text("Up Next", tableName: "Detail")
                                .fontWeight(upNext != .default ? .bold : nil)
                        }
                    } footer: {
                        Text(upNextFooter)
                    }
                }

                Section {
                    Toggle(isOn: $allowsSuggestions) {
                        Text("Allow Suggestions", tableName: "Detail")
                            .fontWeight(allowsSuggestions ? nil : .bold)
                    }
                } footer: {
                    Text("Lets Siri and Spotlight suggest this item based on your listening.", tableName: "Detail")
                }

                if supportsAutoDownload {
                    Section {
                        Picker(selection: $autoDownload) {
                            ForEach(AutoDownloadRule.options(forPodcast: id.kind == .podcast), id: \.self) { rule in
                                Text(rule.localizedName).tag(rule)
                            }
                        } label: {
                            Text("Automatic Downloads", tableName: "Detail")
                                .fontWeight(autoDownload != .disabled ? .bold : nil)
                        }
                    } footer: {
                        Text("Hearth downloads matching items in the background and removes finished ones if enabled in Settings.", tableName: "Detail")
                    }
                }
            }
            .navigationTitle(Text("Configure", tableName: "Detail"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("Configure", tableName: "Detail")
                            .font(.headline)
                        Text(title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) {
                        dismiss()
                    }
                }
            }
            .onAppear(perform: load)
            .onChange(of: rate) { _, value in data.itemSettings.setPlaybackRate(value, for: id) }
            .onChange(of: sleepTimer) { _, value in data.itemSettings.setSleepTimer(value, for: id) }
            .onChange(of: upNext) { _, value in data.itemSettings.setUpNextStrategy(value, for: id) }
            .onChange(of: allowsSuggestions) { _, value in data.itemSettings.setAllowsSuggestions(value, for: id) }
            .onChange(of: autoDownload) { _, value in
                Task { await data.downloads.setAutoDownloadRule(value, for: id) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() {
        rate = data.itemSettings.playbackRate(for: id)
        sleepTimer = data.itemSettings.sleepTimer(for: id)
        upNext = data.itemSettings.upNextStrategy(for: id)
        allowsSuggestions = data.itemSettings.allowsSuggestions(for: id)
        autoDownload = data.downloads.autoDownloadRule(for: id)
    }

    // MARK: Rows

    private var rateOptions: [Double] {
        var values = Set(settings.playbackRatePresets)
        values.formUnion(stride(from: 0.5, through: 3.0, by: 0.1).map { ($0 * 100).rounded() / 100 })
        if let rate { values.insert(rate) }
        return values.sorted()
    }

    private var rateRow: some View {
        Picker(selection: $rate) {
            Text("Default (\(HearthFormat.rate(settings.defaultPlaybackRate)))", tableName: "Detail")
                .tag(Double?.none)
            ForEach(rateOptions, id: \.self) { value in
                Text(HearthFormat.rate(value)).tag(Double?.some(value))
            }
        } label: {
            Label {
                Text("Playback Speed", tableName: "Detail")
                    .fontWeight(rate != nil ? .bold : nil)
            } icon: {
                Image(systemName: "gauge.with.dots.needle.67percent")
            }
        }
        .pickerStyle(.menu)
    }

    private var sleepTimerRow: some View {
        Picker(selection: $sleepTimer) {
            Text("Off", tableName: "Detail").tag(SleepTimerPreset?.none)
            Section {
                ForEach(settings.sleepTimerPresets, id: \.self) { minutes in
                    Text(SleepTimerFormat.minutes(minutes)).tag(SleepTimerPreset?.some(.minutes(minutes)))
                }
            }
            Section {
                ForEach([1, 2, 3, 5, 7, 10], id: \.self) { count in
                    Text(SleepTimerFormat.chapters(count)).tag(SleepTimerPreset?.some(.chapters(count)))
                }
            }
        } label: {
            Label {
                Text("Sleep Timer", tableName: "Detail")
                    .fontWeight(sleepTimer != nil ? .bold : nil)
            } icon: {
                Image(systemName: "moon.zzz")
            }
        }
        .pickerStyle(.menu)
    }

    private var upNextFooter: String {
        switch id.kind {
        case .podcast: String(localized: "“Default” queues the following episodes in your episode order.", table: "Detail")
        default: String(localized: "“Default” queues the following unfinished books of the series.", table: "Detail")
        }
    }
}

extension UpNextStrategy {
    var configureTitle: String {
        switch self {
        case .default: String(localized: "Default", table: "Detail")
        case .listenNow: String(localized: "Listen Now", table: "Detail")
        case .disabled: String(localized: "Disabled", table: "Detail")
        }
    }
}

/// Sleep timer labels shared by the configure sheet.
enum SleepTimerFormat {
    static func minutes(_ minutes: Int) -> String {
        Duration.seconds(Double(minutes) * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    static func chapters(_ count: Int) -> String {
        String(localized: "\(count) chapters", table: "Detail")
    }
}
