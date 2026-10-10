import HearthData
import HearthModel
import HearthUI
import SwiftUI

/// Settings root (sheet on iPhone, sidebar tab on iPad).
struct SettingsView: View {
    /// Embedded as a tab (no Done button).
    var isEmbedded = false

    @Environment(\.dismiss) private var dismiss
    #if DEBUG
    @State private var showsDebugPage = false
    @State private var didShowDebugPage = false
    #endif

    private var settings: AppSettings { .shared }
    private var connections: ConnectionStore { HearthData.shared.connections }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        ConnectionsSettingsView()
                    } label: {
                        SettingsLabel(title: String(localized: "Connections"), systemImage: "server.rack", color: .blue, value: connectionsSummary)
                    }
                    Toggle(isOn: offlineBinding) {
                        SettingsLabel(title: String(localized: "Offline Mode"), systemImage: "icloud.slash", color: .gray)
                    }
                }

                Section {
                    NavigationLink {
                        AppearanceSettingsView()
                    } label: {
                        SettingsLabel(title: String(localized: "Appearance"), systemImage: "paintbrush", color: .hearthTint)
                    }
                    NavigationLink {
                        PlaybackSettingsView()
                    } label: {
                        SettingsLabel(title: String(localized: "Playback"), systemImage: "play.circle", color: .orange)
                    }
                    NavigationLink {
                        SleepTimerSettingsView()
                    } label: {
                        SettingsLabel(title: String(localized: "Sleep Timer"), systemImage: "moon.zzz", color: .indigo)
                    }
                    NavigationLink {
                        LibrarySettingsView()
                    } label: {
                        SettingsLabel(title: String(localized: "Library"), systemImage: "books.vertical", color: .brown)
                    }
                    NavigationLink {
                        DownloadsSettingsView()
                    } label: {
                        SettingsLabel(title: String(localized: "Downloads"), systemImage: "arrow.down.circle", color: .green)
                    }
                    NavigationLink {
                        CarPlaySettingsView()
                    } label: {
                        SettingsLabel(title: String(localized: "CarPlay"), systemImage: "car", color: .teal)
                    }
                    NavigationLink {
                        DailyGoalSettingsView()
                    } label: {
                        SettingsLabel(title: String(localized: "Daily Goal"), systemImage: "target", color: .red, value: String(localized: "\(settings.dailyGoalMinutes) min"))
                    }
                }

                Section {
                    if let shortcuts = URL(string: "shortcuts://") {
                        Link(destination: shortcuts) {
                            SettingsLabel(title: String(localized: "Siri & Shortcuts"), systemImage: "wand.and.stars", color: .pink, isLink: true)
                        }
                        .tint(.primary)
                    }
                    NavigationLink {
                        SupportSettingsView()
                    } label: {
                        SettingsLabel(title: String(localized: "Support"), systemImage: "lifepreserver", color: .cyan)
                    }
                    NavigationLink {
                        AboutView()
                    } label: {
                        SettingsLabel(title: String(localized: "About Hearth"), systemImage: "info.circle", color: .gray)
                    }
                }
            }
            .navigationTitle("Settings")
            #if DEBUG
            .navigationDestination(isPresented: $showsDebugPage) {
                debugPage
            }
            .onAppear {
                if UserDefaults.standard.string(forKey: "HearthDebugSettingsPage") != nil, !didShowDebugPage {
                    didShowDebugPage = true
                    showsDebugPage = true
                }
            }
            #endif
            .toolbar {
                if !isEmbedded {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", systemImage: "checkmark") { dismiss() }
                    }
                }
            }
        }
    }

    #if DEBUG
    /// `-HearthDebugSettingsPage <page>` pushes a settings page at launch (UI checks without tapping).
    @ViewBuilder
    private var debugPage: some View {
        switch UserDefaults.standard.string(forKey: "HearthDebugSettingsPage") {
        case "appearance": AppearanceSettingsView()
        case "playback": PlaybackSettingsView()
        case "sleepTimer": SleepTimerSettingsView()
        case "library": LibrarySettingsView()
        case "downloads": DownloadsSettingsView()
        case "carPlay": CarPlaySettingsView()
        case "goal": DailyGoalSettingsView()
        case "support": SupportSettingsView()
        case "about": AboutView()
        default: ConnectionsSettingsView()
        }
    }
    #endif

    private var connectionsSummary: String {
        let count = connections.connections.count
        if count == 0 {
            return String(localized: "None")
        }
        return count == 1 ? (connections.connections.first?.host.host() ?? "") : String(localized: "\(count) servers")
    }

    private var offlineBinding: Binding<Bool> {
        Binding(
            get: { connections.isOffline },
            set: { value in Task { await connections.setOffline(value) } }
        )
    }
}

/// Settings-style row label with a colored icon tile.
struct SettingsLabel: View {
    let title: String
    let systemImage: String
    let color: Color
    var value: String?
    var isLink = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(color.gradient, in: .rect(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if isLink {
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Daily listening goal.
struct DailyGoalSettingsView: View {
    var body: some View {
        @Bindable var settings = AppSettings.shared
        let listened = HearthData.shared.listening.listenedToday
        Form {
            Section {
                HStack {
                    Spacer()
                    ListenedTodayGauge(listened: listened, goalMinutes: settings.dailyGoalMinutes, lineWidth: 10)
                        .frame(width: 140, height: 140)
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
            Section {
                Stepper(value: $settings.dailyGoalMinutes, in: 5...600, step: 5) {
                    LabeledContent("Daily Goal", value: String(localized: "\(settings.dailyGoalMinutes) min"))
                }
            } footer: {
                Text("Listening time is counted across all your servers and resets at midnight.")
            }
        }
        .navigationTitle("Daily Goal")
    }
}
