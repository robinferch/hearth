import HearthData
import HearthModel
import HearthUI
import SwiftUI

/// Watch settings: playback, sleep timer, downloads, connections.
struct WatchSettingsView: View {
    @Bindable private var settings = AppSettings.shared

    private static let defaultRates: [Double] = [0.75, 0.8, 0.9, 1.0, 1.1, 1.2, 1.25, 1.3, 1.4, 1.5, 1.6, 1.75, 1.8, 2.0, 2.25, 2.5, 3.0]
    private static let sleepTimerOptions = [5, 10, 15, 20, 25, 30, 45, 60, 75, 90, 120]

    var body: some View {
        Form {
            Section("Playback") {
                Picker("Skip Back", selection: $settings.skipBackwardInterval) {
                    ForEach(AppSettings.skipIntervalOptions, id: \.self) { seconds in
                        Text("\(seconds) s").tag(seconds)
                    }
                }
                Picker("Skip Forward", selection: $settings.skipForwardInterval) {
                    ForEach(AppSettings.skipIntervalOptions, id: \.self) { seconds in
                        Text("\(seconds) s").tag(seconds)
                    }
                }
                Picker("Default Speed", selection: $settings.defaultPlaybackRate) {
                    ForEach(rateOptions, id: \.self) { rate in
                        Text(HearthFormat.rate(rate)).tag(rate)
                    }
                }
                NavigationLink {
                    SpeedPresetsView()
                } label: {
                    LabeledContent("Speed Presets", value: settings.playbackRatePresets.sorted().map(HearthFormat.rate).joined(separator: " "))
                }
                Toggle("Smart Rewind", isOn: $settings.smartRewind)
                Toggle("Chapter Progress", isOn: $settings.chapterRelativeProgress)
            }

            Section("Sleep Timer") {
                NavigationLink {
                    SleepTimerPresetsView()
                } label: {
                    LabeledContent("Presets", value: "\(settings.sleepTimerPresets.count)")
                }
                Toggle("Fade Out", isOn: $settings.sleepTimerFadeOut)
            }

            Section {
                Toggle("Use Cellular", isOn: $settings.allowCellularDownloads)
                Toggle("Remove Finished", isOn: $settings.removeFinishedDownloads)
            } header: {
                Text("Downloads")
            } footer: {
                Text("Removes downloads automatically after you finish listening.")
            }

            Section("Daily Goal") {
                Stepper(value: $settings.dailyGoalMinutes, in: 5...600, step: 5) {
                    Text("\(settings.dailyGoalMinutes) min")
                }
            }

            Section {
                NavigationLink(value: WatchRoute.connections) {
                    Label("Servers", systemImage: "server.rack")
                }
            }

            Section {
                LabeledContent("Version", value: Self.version)
            } footer: {
                Text("Hearth is free and open source (MIT).")
            }
        }
        .navigationTitle("Settings")
    }

    private var rateOptions: [Double] {
        Array(Set(Self.defaultRates + [settings.defaultPlaybackRate])).sorted()
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    /// Toggle list of speed presets (at least one remains).
    private struct SpeedPresetsView: View {
        @Bindable private var settings = AppSettings.shared

        var body: some View {
            List {
                ForEach(WatchSettingsView.defaultRates, id: \.self) { rate in
                    Toggle(HearthFormat.rate(rate), isOn: Binding(
                        get: { settings.playbackRatePresets.contains { abs($0 - rate) < 0.001 } },
                        set: { enabled in
                            var presets = settings.playbackRatePresets.filter { abs($0 - rate) >= 0.001 }
                            if enabled {
                                presets.append(rate)
                            }
                            guard !presets.isEmpty else { return }
                            settings.playbackRatePresets = presets.sorted()
                        }
                    ))
                }
            }
            .navigationTitle("Speed Presets")
        }
    }

    /// Toggle list of sleep timer presets (at least one remains).
    private struct SleepTimerPresetsView: View {
        @Bindable private var settings = AppSettings.shared

        var body: some View {
            List {
                ForEach(WatchSettingsView.sleepTimerOptions, id: \.self) { minutes in
                    Toggle(isOn: Binding(
                        get: { settings.sleepTimerPresets.contains(minutes) },
                        set: { enabled in
                            var presets = settings.sleepTimerPresets.filter { $0 != minutes }
                            if enabled {
                                presets.append(minutes)
                            }
                            guard !presets.isEmpty else { return }
                            settings.sleepTimerPresets = presets.sorted()
                        }
                    )) {
                        Text(Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                    }
                }
            }
            .navigationTitle("Sleep Timer")
        }
    }
}

/// Signed-in servers: sync from iPhone, sign out.
struct ConnectionsView: View {
    @State private var isSyncing = false
    @State private var message: String?
    @State private var removing: Connection?

    private var store: ConnectionStore { HearthData.shared.connections }

    var body: some View {
        List {
            Section {
                ForEach(store.connections) { connection in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connection.username)
                            .font(.headline)
                        Text(connection.host.host() ?? connection.host.absoluteString)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        statusLabel(for: connection)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            removing = connection
                        } label: {
                            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                }
            }

            Section {
                Button {
                    Task { await syncFromPhone() }
                } label: {
                    if isSyncing {
                        ProgressView()
                    } else {
                        Label("Sync from iPhone", systemImage: "iphone.and.arrow.forward")
                    }
                }
                .disabled(isSyncing)
            } footer: {
                if let message {
                    Text(message)
                }
            }

            Section {
                NavigationLink {
                    ManualSignInView()
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
            }
        }
        .navigationTitle("Servers")
        .confirmationDialog("Sign out of this server? Downloads from it are removed.", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { connection in
            Button("Sign Out", role: .destructive) {
                Task { await store.remove(connection.id) }
            }
        }
    }

    @ViewBuilder
    private func statusLabel(for connection: Connection) -> some View {
        switch store.status[connection.id] {
        case .online:
            Label("Online", systemImage: "circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        case .offline:
            Label("Offline", systemImage: "circle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .unauthorized:
            Label("Sign-in expired", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
        case .loading, nil:
            EmptyView()
        }
    }

    private func syncFromPhone() async {
        isSyncing = true
        message = nil
        defer { isSyncing = false }
        guard PhoneLink.shared.isReachable else {
            message = String(localized: "Your iPhone isn't reachable. Open Hearth on it and keep it nearby.")
            return
        }
        do {
            let count = try await PhoneLink.shared.requestCredentials()
            message = count == 0 ? String(localized: "Everything is up to date.") : String(localized: "Updated \(count) server(s).")
        } catch {
            message = String(localized: "Your iPhone didn't respond. Open Hearth on it and try again.")
        }
    }
}
