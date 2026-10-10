import HearthData
import HearthModel
import HearthUI
import SwiftUI

/// CarPlay: Listen Now tab, ordered library tabs (max 3 + Listen Now + Other), other libraries.
struct CarPlaySettingsView: View {
    private var connections: ConnectionStore { HearthData.shared.connections }

    var body: some View {
        @Bindable var settings = AppSettings.shared
        let selected = settings.carPlayLibraries.compactMap { key in connections.allLibraries.first { $0.id.description == key } }
        let unselected = connections.allLibraries.filter { !settings.carPlayLibraries.contains($0.id.description) }

        Form {
            Section {
                Toggle("Listen Now", isOn: $settings.carPlayShowListenNow)
            } footer: {
                Text("In-progress and downloaded items from all your libraries.")
            }

            Section {
                if selected.isEmpty {
                    Text("No libraries selected.")
                        .foregroundStyle(.secondary)
                }
                ForEach(selected) { library in
                    Label(library.name, systemImage: library.systemImage)
                }
                .onMove { source, destination in
                    settings.carPlayLibraries.move(fromOffsets: source, toOffset: destination)
                }
                .onDelete { offsets in
                    settings.carPlayLibraries.remove(atOffsets: offsets)
                }
            } header: {
                Text("Library Tabs")
            } footer: {
                Text("CarPlay shows up to 5 tabs.")
            }

            if !unselected.isEmpty {
                Section("Add Library") {
                    ForEach(unselected) { library in
                        Button {
                            settings.carPlayLibraries.append(library.id.description)
                        } label: {
                            HStack {
                                Label(library.name, systemImage: library.systemImage)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(.green)
                                    .accessibilityLabel("Add")
                            }
                        }
                        .disabled(maxReached(selectedCount: selected.count))
                    }
                }
            }

            Section {
                Toggle("Other Libraries", isOn: $settings.carPlayShowOtherLibraries)
            } footer: {
                Text("Adds a tab with all libraries that don't have their own tab.")
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("CarPlay")
    }

    private func maxReached(selectedCount: Int) -> Bool {
        let settings = AppSettings.shared
        let fixed = (settings.carPlayShowListenNow ? 1 : 0) + (settings.carPlayShowOtherLibraries ? 1 : 0)
        return selectedCount + fixed >= 5
    }
}
