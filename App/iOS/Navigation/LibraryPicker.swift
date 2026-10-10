import HearthData
import HearthModel
import HearthUI
import SwiftUI

/// Toolbar menu: libraries grouped by server, pinned tabs mode, settings, offline toggle,
/// connection status and "Customize tabs".
struct LibraryPickerMenu: View {
    @Environment(Navigator.self) private var navigator

    private var connections: ConnectionStore { HearthData.shared.connections }

    var body: some View {
        Menu {
            ForEach(connections.connections) { connection in
                Section(connections.connections.count > 1 ? connection.displayName : String(localized: "Libraries")) {
                    ForEach(connections.libraries[connection.id] ?? []) { library in
                        Button {
                            navigator.select(library: library)
                        } label: {
                            if !navigator.isPinnedMode, navigator.currentLibrary == library.id {
                                Label(library.name, systemImage: "checkmark")
                            } else {
                                Label(library.name, systemImage: library.systemImage)
                            }
                        }
                    }
                }
            }

            Section {
                Button {
                    if HearthData.shared.itemSettings.pinnedTabs.isEmpty {
                        navigator.sheet = .pinnedTabs
                    } else {
                        navigator.isPinnedMode.toggle()
                    }
                } label: {
                    Label("Pinned Tabs", systemImage: navigator.isPinnedMode ? "checkmark" : "pin")
                }
                if let library = navigator.resolvedLibrary(connections: connections) {
                    Button {
                        navigator.sheet = navigator.isPinnedMode ? .pinnedTabs : .customizeTabs(library.id)
                    } label: {
                        Label("Customize Tabs", systemImage: "square.grid.2x2")
                    }
                }
            }

            Section {
                ConnectionStatusMenuItem()
                Button {
                    Task { await connections.setOffline(true) }
                } label: {
                    Label("Go Offline", systemImage: "icloud.slash")
                }
                Button {
                    navigator.sheet = .settings
                } label: {
                    Label("Settings", systemImage: "gear")
                }
            }
        } label: {
            Label(title, systemImage: "books.vertical")
                .labelStyle(.iconOnly)
        }
        .accessibilityLabel("Libraries")
        .accessibilityValue(title)
    }

    private var title: String {
        if navigator.isPinnedMode {
            return String(localized: "Pinned Tabs")
        }
        return navigator.resolvedLibrary(connections: connections)?.name ?? String(localized: "Libraries")
    }
}

/// "N offline – Retry" entry, only when some connections are unreachable.
struct ConnectionStatusMenuItem: View {
    private var connections: ConnectionStore { HearthData.shared.connections }

    var body: some View {
        let offline = connections.connections.filter { connections.status[$0.id] == .offline || connections.status[$0.id] == .unauthorized }
        if !offline.isEmpty {
            Button {
                Task { await connections.retryOffline() }
            } label: {
                Label {
                    Text("Retry Connections")
                    Text("\(offline.count) offline")
                } icon: {
                    Image(systemName: "exclamationmark.icloud")
                }
            }
        }
    }
}

/// Listened-today gauge toolbar button. Tap → Listen Now sheet; long-press → goal −/+.
struct ListenedTodayButton: View {
    @Environment(Navigator.self) private var navigator
    @Environment(\.listenNowNamespace) private var namespace

    private var settings: AppSettings { .shared }

    var body: some View {
        let listened = HearthData.shared.listening.listenedToday
        Menu {
            Section("Daily Goal: \(settings.dailyGoalMinutes) min") {
                Button {
                    settings.dailyGoalMinutes += 5
                } label: {
                    Label("Increase Goal", systemImage: "plus")
                }
                Button {
                    settings.dailyGoalMinutes = max(5, settings.dailyGoalMinutes - 5)
                } label: {
                    Label("Decrease Goal", systemImage: "minus")
                }
            }
        } label: {
            ListenedTodayGauge(listened: listened, goalMinutes: settings.dailyGoalMinutes, lineWidth: 2.5)
                .frame(width: 26, height: 26)
        } primaryAction: {
            navigator.sheet = .listenNow
        }
        .modifier(ListenNowSourceModifier(namespace: namespace))
        .accessibilityLabel("Listen Now")
        .accessibilityValue("\(Int(listened / 60)) of \(settings.dailyGoalMinutes) minutes listened today")
    }
}

private struct ListenNowSourceModifier: ViewModifier {
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedTransitionSource(id: ListenNowView.transitionID, in: namespace)
        } else {
            content
        }
    }
}

extension EnvironmentValues {
    /// Namespace for the listened-today button → Listen Now sheet zoom transition.
    @Entry var listenNowNamespace: Namespace.ID?
}

extension View {
    /// Standard root toolbar on iPhone: library picker (leading) and listened-today gauge (trailing).
    func libraryRootToolbar(showsListenNow: Bool = true) -> some View {
        modifier(LibraryRootToolbar(showsListenNow: showsListenNow))
    }
}

private struct LibraryRootToolbar: ViewModifier {
    let showsListenNow: Bool

    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        content.toolbar {
            if sizeClass == .compact {
                ToolbarItem(placement: .topBarLeading) {
                    LibraryPickerMenu()
                }
            }
            if showsListenNow {
                ToolbarItem(placement: .topBarTrailing) {
                    ListenedTodayButton()
                }
            }
        }
    }
}
