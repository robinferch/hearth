import HearthData
import HearthModel
import HearthPlayback
import HearthUI
import SwiftUI

/// Main navigation: tab bar on iPhone (current library's tabs + Search), sidebar on iPad
/// (Listen Now, Search, one section per library, Settings).
struct MainTabView: View {
    @Environment(Navigator.self) private var navigator
    @Environment(PlayerPresentation.self) private var player
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.playerNamespace) private var playerNamespace

    @AppStorage("tabViewCustomization") private var customization: TabViewCustomization

    private var connections: ConnectionStore { HearthData.shared.connections }
    private var pinned: [PinnedTab] { HearthData.shared.itemSettings.pinnedTabs }
    private var isCompact: Bool { sizeClass == .compact }

    var body: some View {
        @Bindable var navigator = navigator
        @Bindable var player = player

        TabView(selection: $navigator.selectedTab) {
            if isCompact {
                compactTabs
            } else {
                sidebarTabs
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewCustomization($customization)
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewSidebarHeader {
            ListenedTodaySidebarRow()
        }
        .tabViewSidebarBottomBar {
            SidebarBottomBar()
        }
        .modifier(MiniPlayerAccessory())
        .fullScreenCover(isPresented: $player.isExpanded) {
            NowPlayingView()
                .sceneAlertHost()
                .modifier(ZoomTransition(sourceID: PlayerPresentation.transitionSourceID, namespace: playerNamespace))
        }
        .onAppear(perform: validate)
        .onChange(of: connections.allLibraries) { validate() }
        .onChange(of: isCompact) { validate() }
        .onChange(of: navigator.isPinnedMode) { validate() }
        // Customized / pinned / iCloud-synced tab bars may drop the selected tab.
        .onChange(of: isCompact ? navigator.compactTabs(connections: connections, pinned: pinned) : []) { validate() }
    }

    private func validate() {
        navigator.validateSelection(connections: connections, pinned: pinned, compact: isCompact)
    }

    // MARK: iPhone

    @TabContentBuilder<TabValue>
    private var compactTabs: some TabContent<TabValue> {
        let tabs = navigator.compactTabs(connections: connections, pinned: pinned)
        if tabs.isEmpty {
            Tab(String(localized: "Library"), systemImage: "books.vertical", value: TabValue.noLibrary) {
                TabRoot(tab: .noLibrary) {
                    NoLibraryView()
                }
            }
        }
        ForEach(tabs, id: \.self) { value in
            Tab(title(for: value, among: tabs), systemImage: value.libraryTab?.systemImage ?? "square", value: value) {
                tabContent(value)
            }
        }
        Tab(value: TabValue.search, role: .search) {
            TabRoot(tab: .search) {
                SearchView()
            }
        }
    }

    /// Pinned tabs from different libraries are labelled with the library name when ambiguous.
    private func title(for value: TabValue, among tabs: [TabValue]) -> String {
        guard case .library(let library, let tab) = value else { return "" }
        let duplicates = tabs.filter { $0.libraryTab == tab }.count > 1
        if duplicates, let name = connections.library(library)?.name {
            return name
        }
        return tab.title
    }

    // MARK: iPad

    @TabContentBuilder<TabValue>
    private var sidebarTabs: some TabContent<TabValue> {
        Tab(String(localized: "Listen Now"), systemImage: "play.square.stack", value: TabValue.listenNow) {
            TabRoot(tab: .listenNow) {
                ListenNowView(isSheet: false)
            }
        }
        .customizationID(TabValue.listenNow.customizationID)

        Tab(value: TabValue.search, role: .search) {
            TabRoot(tab: .search) {
                SearchView()
            }
        }
        .customizationID(TabValue.search.customizationID)

        if connections.allLibraries.isEmpty {
            Tab(String(localized: "Library"), systemImage: "books.vertical", value: TabValue.noLibrary) {
                TabRoot(tab: .noLibrary) {
                    NoLibraryView()
                }
            }
        }

        ForEach(connections.allLibraries) { library in
            TabSection(sectionTitle(for: library)) {
                ForEach(LibraryTab.available(for: library.mediaType), id: \.self) { tab in
                    let value = TabValue.library(library.id, tab)
                    Tab(tab.title, systemImage: tab.systemImage, value: value) {
                        tabContent(value)
                    }
                    .customizationID(value.customizationID)
                    .defaultVisibility(LibraryTab.defaults(for: library.mediaType).contains(tab) ? .visible : .hidden, for: .tabBar)
                }
            }
            .customizationID("section::\(library.id.description)")
        }

        Tab(String(localized: "Settings"), systemImage: "gear", value: TabValue.settings) {
            SettingsView(isEmbedded: true)
        }
        .customizationID(TabValue.settings.customizationID)
        .defaultVisibility(.hidden, for: .tabBar)
    }

    private func sectionTitle(for library: Library) -> String {
        guard connections.connections.count > 1, let connection = connections.connection(library.connectionID) else {
            return library.name
        }
        return "\(library.name) · \(connection.host.host() ?? connection.displayName)"
    }

    // MARK: Content

    @ViewBuilder
    private func tabContent(_ value: TabValue) -> some View {
        if case .library(let library, let tab) = value {
            TabRoot(tab: value) {
                LibraryTabScreen(library: library, tab: tab, isRoot: true)
            }
        }
    }
}

/// Mini player in the tab view's bottom accessory, when something is playing or resumable.
private struct MiniPlayerAccessory: ViewModifier {
    func body(content: Content) -> some View {
        let player = AudioPlayer.shared
        let enabled = player.currentItem != nil || player.lastPlayedItemID != nil
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: enabled) {
                MiniPlayerView()
            }
        } else if enabled {
            content.tabViewBottomAccessory {
                MiniPlayerView()
            }
        } else {
            content
        }
    }
}

/// iPad sidebar bottom bar: Settings and offline toggle.
private struct SidebarBottomBar: View {
    @Environment(Navigator.self) private var navigator

    var body: some View {
        HStack {
            Button {
                navigator.sheet = .settings
            } label: {
                Label("Settings", systemImage: "gear")
            }
            Spacer()
            Button {
                Task { await HearthData.shared.connections.setOffline(true) }
            } label: {
                Label("Go Offline", systemImage: "icloud.slash")
            }
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// No library available yet: loading, connection failure or empty server.
struct NoLibraryView: View {
    private var connections: ConnectionStore { HearthData.shared.connections }

    var body: some View {
        Group {
            if let failed = connections.connections.first(where: { connections.status[$0.id] == .offline }) {
                ConnectionFailureView(connectionID: failed.id)
            } else if connections.connections.allSatisfy({ connections.status[$0.id] == .online }) {
                ContentUnavailableView {
                    Label("No Libraries", systemImage: "books.vertical")
                } description: {
                    Text("Your server doesn't have any libraries you can access.")
                } actions: {
                    Button("Reload") {
                        Task { await connections.reloadLibraries() }
                    }
                    .buttonStyle(.glass)
                }
            } else {
                LoadingView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                LibraryPickerMenu()
            }
        }
    }
}
