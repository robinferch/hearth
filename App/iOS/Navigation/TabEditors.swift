import HearthData
import HearthModel
import HearthUI
import SwiftUI

/// Chooses and orders the (max 5) tabs of a library on iPhone.
struct TabCustomizationEditor: View {
    let library: Library

    @Environment(\.dismiss) private var dismiss
    @State private var selected: [LibraryTab] = []

    private var unselected: [LibraryTab] {
        LibraryTab.available(for: library.mediaType).filter { !selected.contains($0) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(selected, id: \.self) { tab in
                        Label(tab.title, systemImage: tab.systemImage)
                    }
                    .onMove { selected.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { offsets in
                        guard selected.count - offsets.count >= 1 else { return }
                        selected.remove(atOffsets: offsets)
                    }
                } header: {
                    Text("Tab Bar")
                } footer: {
                    Text("Up to 5 tabs. Search is always available.")
                }
                Section("More Tabs") {
                    ForEach(unselected, id: \.self) { tab in
                        Button {
                            withAnimation { selected.append(tab) }
                        } label: {
                            HStack {
                                Label(tab.title, systemImage: tab.systemImage)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(.green)
                                    .accessibilityLabel("Add")
                            }
                        }
                        .disabled(selected.count >= 5)
                    }
                }
                Section {
                    Button("Reset to Defaults") {
                        selected = LibraryTab.defaults(for: library.mediaType)
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(library.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") {
                        HearthData.shared.itemSettings.setTabs(selected, for: library.id)
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
            .onAppear {
                selected = library.configuredTabs
            }
        }
    }
}

/// Builds the user's pinned tabs (mixed tabs from any library).
struct PinnedTabsEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Navigator.self) private var navigator

    @State private var pinned: [PinnedTab] = []

    private var connections: ConnectionStore { HearthData.shared.connections }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if pinned.isEmpty {
                        Text("Pin tabs from any library to build your own tab bar.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(pinned) { pin in
                        label(for: pin)
                    }
                    .onMove { pinned.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { pinned.remove(atOffsets: $0) }
                } header: {
                    Text("Pinned Tabs")
                } footer: {
                    Text("Up to 5 pinned tabs are shown in the tab bar.")
                }
                ForEach(connections.allLibraries) { library in
                    Section(library.name) {
                        ForEach(LibraryTab.available(for: library.mediaType), id: \.self) { tab in
                            let pin = PinnedTab(library: library.id, tab: tab)
                            if !pinned.contains(pin) {
                                Button {
                                    withAnimation { pinned.append(pin) }
                                } label: {
                                    HStack {
                                        Label(tab.title, systemImage: tab.systemImage)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        Image(systemName: "pin.circle.fill")
                                            .foregroundStyle(.tint)
                                            .accessibilityLabel("Pin")
                                    }
                                }
                                .disabled(pinned.count >= 5)
                            }
                        }
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Pinned Tabs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") {
                        HearthData.shared.itemSettings.pinnedTabs = pinned
                        navigator.isPinnedMode = !pinned.isEmpty
                        if let first = pinned.first, navigator.isPinnedMode {
                            navigator.selectedTab = .library(first.library, first.tab)
                        }
                        dismiss()
                    }
                }
            }
            .onAppear {
                pinned = HearthData.shared.itemSettings.pinnedTabs
            }
        }
    }

    private func label(for pin: PinnedTab) -> some View {
        Label {
            VStack(alignment: .leading) {
                Text(pin.tab.title)
                Text(connections.library(pin.library)?.name ?? String(localized: "Unavailable Library"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: pin.tab.systemImage)
        }
    }
}
