import HearthData
import HearthModel
import HearthPlayback
import HearthUI
import OSLog
import SwiftUI

/// Root of a window: loading → welcome → offline → main UI, plus scene-wide sheets, alerts,
/// URL / Handoff handling and environment setup.
struct RootView: View {
    @State private var navigator = Navigator()
    @State private var alerts = AlertCenter()
    @State private var player = PlayerPresentation()

    @Namespace private var playerNamespace
    @Namespace private var listenNowNamespace

    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    private var data: HearthData { .shared }
    private var connections: ConnectionStore { HearthData.shared.connections }
    private var events: AppEvents { .shared }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hearth", category: "RootView")

    var body: some View {
        content
            .animation(.smooth, value: phase)
            .sceneSheets(navigator: navigator, alerts: alerts, player: player, handler: handler)
            .sheet(isPresented: reauthorizationBinding) {
                if let id = connections.connectionNeedingReauthorization, let connection = connections.connection(id) {
                    ReauthorizationSheet(connection: connection)
                        .hearthSceneEnvironment(navigator: navigator, alerts: alerts, player: player, handler: handler)
                }
            }
            .sensoryFeedback(.success, trigger: alerts.successTrigger)
            .sensoryFeedback(.error, trigger: alerts.errorTrigger)
            .hearthSceneEnvironment(navigator: navigator, alerts: alerts, player: player, handler: handler)
            .environment(\.playerNamespace, playerNamespace)
            .environment(\.listenNowNamespace, listenNowNamespace)
            .focusedSceneValue(\.navigator, navigator)
            .onOpenURL(perform: handle(url:))
            .onContinueUserActivity(UserActivity.itemType) { activity in
                if let id = UserActivity.itemID(from: activity) {
                    handle(.open(id))
                }
            }
            .onChange(of: events.pending, initial: true) { _, request in
                guard request != nil, phase == .main || phase == .offline, let request = events.consume() else { return }
                handle(request)
            }
            .onChange(of: phase) { _, newPhase in
                if newPhase == .main, let request = events.consume() {
                    handle(request)
                }
            }
            #if DEBUG
            .task {
                // `-HearthDebugSheet settings|addConnection|listenNow` opens a sheet at launch (screenshots, UI checks).
                switch UserDefaults.standard.string(forKey: "HearthDebugSheet") {
                case "settings": navigator.sheet = .settings
                case "addConnection": navigator.sheet = .addConnection
                case "listenNow": navigator.sheet = .listenNow
                default: break
                }
                await DebugSupport.performLaunchActions()
            }
            #endif
            .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
                // Extends the sleep timer when `AppSettings.shakeExtendsSleepTimer` is on.
                AudioPlayer.shared.handleShake()
            }
    }

    // MARK: Phases

    private var phase: RootPhase {
        if let route = DebugLaunchRoute.current {
            return route.phase
        }
        if !connections.isLoaded, !events.bootstrapFinished {
            return .loading
        }
        if connections.connections.isEmpty {
            return .welcome
        }
        return connections.isOffline ? .offline : .main
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            LoadingView()
                .transition(.opacity)
        case .welcome:
            WelcomeView()
                .transition(.opacity)
        case .offline:
            OfflineView()
                .transition(.opacity)
        case .main:
            MainTabView()
                .transition(.opacity)
        }
    }

    // MARK: Actions

    private var handler: ItemActionHandler {
        AppItemActions.handler(navigator: navigator, alerts: alerts, player: player, openWindow: supportsMultipleWindows ? openWindow : nil)
    }

    private func handle(url: URL) {
        if let request = DeepLink.request(for: url) {
            handle(request)
        }
    }

    private func handle(_ request: ExternalRequest) {
        switch request {
        case .open(let id):
            navigator.sheet = nil
            player.collapse()
            navigator.open(id, connections: connections)
        case .play(let id):
            Task { await AppItemActions.play(id, alerts: alerts, player: player) }
        case .search(let query):
            navigator.sheet = nil
            player.collapse()
            navigator.showSearch(query: query)
        }
    }

    private var reauthorizationBinding: Binding<Bool> {
        Binding(
            get: { connections.connectionNeedingReauthorization != nil },
            set: { if !$0 { connections.connectionNeedingReauthorization = nil } }
        )
    }
}

private extension WarningAlert.Action.Role {
    var buttonRole: ButtonRole? {
        switch self {
        case .normal: nil
        case .destructive: .destructive
        case .cancel: .cancel
        }
    }
}

// MARK: - Scene environment

extension View {
    /// Tint, color scheme and the scene's observable coordinators, plus the scene's alerts (when this is the
    /// topmost presentation). Applied to the root, sheets and item windows.
    func hearthSceneEnvironment(navigator: Navigator, alerts: AlertCenter, player: PlayerPresentation, handler: ItemActionHandler) -> some View {
        modifier(SceneEnvironmentModifier(navigator: navigator, alerts: alerts, player: player, handler: handler))
    }

    /// Presents the scene's alerts and the bookmark prompt from a full-screen cover (e.g. the player), which
    /// hides the views below it. Reads the coordinators from the environment.
    func sceneAlertHost() -> some View {
        modifier(EnvironmentAlertHost())
    }

    /// Presents `Navigator.sheet` (main window and item windows).
    func sceneSheets(navigator: Navigator, alerts: AlertCenter, player: PlayerPresentation, handler: ItemActionHandler) -> some View {
        sheet(item: Bindable(navigator).sheet) { sheet in
            SceneSheetContent(sheet: sheet)
                .hearthSceneEnvironment(navigator: navigator, alerts: alerts, player: player, handler: handler)
        }
    }
}

/// Content of the scene-level sheets.
private struct SceneSheetContent: View {
    let sheet: AppSheet

    @Environment(\.listenNowNamespace) private var listenNowNamespace

    private var connections: ConnectionStore { HearthData.shared.connections }

    var body: some View {
        switch sheet {
        case .settings:
            SettingsView()
                .presentationSizing(.page)
        case .listenNow:
            NavigationStack {
                ListenNowView()
                    .hearthNavigationDestinations()
            }
            .modifier(ZoomTransition(sourceID: ListenNowView.transitionID, namespace: listenNowNamespace))
        case .addConnection:
            AddConnectionView()
        case .addTo(let id):
            AddToSheet(itemID: id)
        case .customizeTabs(let libraryID):
            if let library = connections.library(libraryID) {
                TabCustomizationEditor(library: library)
            }
        case .pinnedTabs:
            PinnedTabsEditor()
        }
    }
}

private struct SceneEnvironmentModifier: ViewModifier {
    let navigator: Navigator
    let alerts: AlertCenter
    let player: PlayerPresentation
    let handler: ItemActionHandler

    func body(content: Content) -> some View {
        let settings = AppSettings.shared
        content
            .modifier(SceneAlertHost(alerts: alerts, navigator: navigator))
            .tint(settings.tintColor.color)
            .environment(\.hearthAccent, settings.tintColor.accent)
            .preferredColorScheme(settings.colorScheme.colorScheme)
            .environment(navigator)
            .environment(alerts)
            .environment(player)
            .environment(\.itemActionHandler, handler)
    }
}

/// The scene's warning alerts and bookmark prompt. Every presentation level (root, sheet, player cover) has a
/// host; only the topmost presents, so alerts triggered while a sheet or the player is up are visible.
private struct SceneAlertHost: ViewModifier {
    let alerts: AlertCenter
    let navigator: Navigator

    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .alert(alerts.alert?.title ?? "", isPresented: alertBinding, presenting: alerts.alert) { alert in
                ForEach(alert.actions) { action in
                    Button(action.title, role: action.role.buttonRole) {
                        Task { await action.perform() }
                    }
                }
            } message: { alert in
                if let message = alert.message {
                    Text(message)
                }
            }
            .modifier(BookmarkPrompt(isPresented: bookmarkBinding, alerts: alerts))
            .onAppear { alerts.registerHost(id) }
            .onDisappear { alerts.unregisterHost(id) }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { alerts.alert != nil && alerts.isTopmostHost(id) },
            set: { if !$0, alerts.isTopmostHost(id) { alerts.alert = nil } }
        )
    }

    private var bookmarkBinding: Binding<Bool> {
        Binding(
            get: { navigator.isBookmarkPromptPresented && alerts.isTopmostHost(id) },
            set: { if !$0, alerts.isTopmostHost(id) { navigator.isBookmarkPromptPresented = false } }
        )
    }
}

/// `SceneAlertHost` with the coordinators from the environment.
private struct EnvironmentAlertHost: ViewModifier {
    @Environment(AlertCenter.self) private var alerts
    @Environment(Navigator.self) private var navigator

    func body(content: Content) -> some View {
        content.modifier(SceneAlertHost(alerts: alerts, navigator: navigator))
    }
}

/// Note prompt for a new bookmark (⌘B / player).
private struct BookmarkPrompt: ViewModifier {
    @Binding var isPresented: Bool
    let alerts: AlertCenter

    @State private var note = ""

    func body(content: Content) -> some View {
        content.alert("New Bookmark", isPresented: $isPresented) {
            TextField("Note", text: $note)
            Button("Create") {
                let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
                note = ""
                Task {
                    do {
                        try await AudioPlayer.shared.createBookmark(note: text.isEmpty ? nil : text)
                        alerts.succeed()
                    } catch {
                        alerts.fail(error)
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                note = ""
            }
        } message: {
            Text("Leave the note empty to use the current date and time.")
        }
    }
}

// MARK: - Debug routes

private enum RootPhase: Hashable {
    case loading
    case welcome
    case offline
    case main
}

/// DEBUG-only launch argument `-HearthDebugRoute welcome|offline|main` to inspect screens without a server.
private enum DebugLaunchRoute {
    case welcome
    case offline
    case main

    static var current: DebugLaunchRoute? {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "HearthDebugRoute") {
        case "welcome": .welcome
        case "offline": .offline
        case "main": .main
        default: nil
        }
        #else
        nil
        #endif
    }

    var phase: RootPhase {
        switch self {
        case .welcome: .welcome
        case .offline: .offline
        case .main: .main
        }
    }
}
