import HearthData
import HearthModel
import HearthUI
import SwiftUI

struct LibrarySettingsView: View {
    @Environment(Navigator.self) private var navigator

    private var connections: ConnectionStore { HearthData.shared.connections }

    var body: some View {
        @Bindable var settings = AppSettings.shared
        Form {
            Section {
                Toggle("Group Books in Series", isOn: $settings.groupBooksInSeries)
                Toggle("Show Single-Book Series", isOn: $settings.showSingleEntrySeries)
                    .disabled(!settings.groupBooksInSeries)
            } header: {
                Text("Audiobooks")
            } footer: {
                Text("When off, series with only one book show the book instead.")
            }

            Section("Home") {
                Toggle("Show Authors Row", isOn: $settings.showAuthorsRow)
                Toggle("Hide Discover", isOn: $settings.hideDiscoverRow)
            }

            Section("Podcasts") {
                Picker("Default Episode Order", selection: $settings.defaultEpisodeSort) {
                    ForEach(EpisodeSortOrder.allCases, id: \.self) { order in
                        Text(order.title).tag(order)
                    }
                }
                Picker("Direction", selection: $settings.defaultEpisodeSortDirection) {
                    Text("Ascending").tag(SortDirection.ascending)
                    Text("Descending").tag(SortDirection.descending)
                }
            }

            Section {
                ForEach(connections.allLibraries) { library in
                    NavigationLink {
                        TabCustomizationEditor(library: library)
                    } label: {
                        LabeledContent {
                            Text(library.configuredTabs.map(\.title).joined(separator: ", "))
                                .lineLimit(1)
                        } label: {
                            Label(library.name, systemImage: library.systemImage)
                        }
                    }
                }
                NavigationLink {
                    PinnedTabsEditor()
                } label: {
                    Label("Pinned Tabs", systemImage: "pin")
                }
            } header: {
                Text("Tabs")
            } footer: {
                Text("Choose which tabs appear in the tab bar on iPhone.")
            }
        }
        .navigationTitle("Library")
    }
}

extension EpisodeSortOrder {
    var title: String {
        switch self {
        case .name: String(localized: "Name")
        case .index: String(localized: "Episode Number")
        case .released: String(localized: "Release Date")
        case .duration: String(localized: "Duration")
        }
    }
}
