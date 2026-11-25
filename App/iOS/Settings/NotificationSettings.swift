import HearthData
import HearthModel
import HearthUI
import SwiftUI
import UserNotifications

/// New-episode notifications: on/off (with permission handling) and per podcast.
struct NotificationSettingsView: View {
    @Environment(\.openURL) private var openURL
    @State private var status: UNAuthorizationStatus?
    @State private var podcasts: [Podcast]?
    @State private var isEnabling = false

    var body: some View {
        let settings = AppSettings.shared
        Form {
            Section {
                Toggle(isOn: Binding(get: { settings.newEpisodeNotifications && status != .denied }, set: setEnabled)) {
                    HStack {
                        Text("New Episodes", tableName: "Notifications")
                        if isEnabling {
                            ProgressView()
                        }
                    }
                }
                .disabled(isEnabling)
            } footer: {
                Text("Hearth checks your podcasts in the background. iOS decides when that happens, so notifications can arrive with a delay.", tableName: "Notifications")
            }

            if status == .denied {
                Section {
                    Button(String(localized: "Open Settings", table: "Notifications")) {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                            openURL(url)
                        }
                    }
                } footer: {
                    Text("Notifications are turned off for Hearth in the Settings app.", tableName: "Notifications")
                }
            }

            if settings.newEpisodeNotifications, status != .denied {
                Section {
                    if let podcasts {
                        if podcasts.isEmpty {
                            Text("No podcasts", tableName: "Notifications")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(podcasts, id: \.id) { podcast in
                            Toggle(isOn: Binding(
                                get: { settings.notificationsEnabled(for: podcast.id) },
                                set: { settings.setNotificationsEnabled($0, for: podcast.id) }
                            )) {
                                HStack(spacing: 12) {
                                    ItemImage(id: podcast.id, size: .tiny, cornerRadius: 6)
                                        .frame(width: 36, height: 36)
                                    Text(podcast.name)
                                        .lineLimit(2)
                                }
                            }
                        }
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    }
                } header: {
                    Text("Podcasts", tableName: "Notifications")
                }
            }
        }
        .navigationTitle(String(localized: "Notifications", table: "Notifications"))
        .task {
            status = await EpisodeNotifier.shared.authorizationStatus()
        }
        .task(id: settings.newEpisodeNotifications) {
            guard settings.newEpisodeNotifications, podcasts == nil else { return }
            podcasts = await Self.loadPodcasts()
        }
    }

    private func setEnabled(_ enabled: Bool) {
        if !enabled {
            EpisodeNotifier.shared.disable()
            return
        }
        isEnabling = true
        Task {
            _ = await EpisodeNotifier.shared.enable()
            status = await EpisodeNotifier.shared.authorizationStatus()
            isEnabling = false
        }
    }

    /// All podcasts of the available podcast libraries, by name.
    private static func loadPodcasts() async -> [Podcast] {
        let connections = HearthData.shared.connections
        var result: [Podcast] = []
        for library in connections.allLibraries where library.mediaType == .podcasts && connections.isAvailable(library.id.connectionID) {
            guard let client = try? connections.client(for: library.id.connectionID),
                  let page = try? await client.podcasts(library: library.id, sort: .title, direction: .ascending, page: 0, limit: 500) else { continue }
            result += page.items
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
