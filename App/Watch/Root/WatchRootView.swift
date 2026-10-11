import HearthData
import HearthModel
import HearthUI
import SwiftUI

/// Navigation destinations of the watch app.
enum WatchRoute: Hashable {
    case nowPlaying
    case playerOptions
    case chapters
    case playbackSpeed
    case sleepTimer
    case scrub
    case listenNow
    case library(LibraryIdentifier)
    case audiobooks(LibraryIdentifier)
    case series(LibraryIdentifier)
    case authors(LibraryIdentifier)
    case podcasts(LibraryIdentifier)
    /// Any item: audiobook / episode detail, series, author or podcast.
    case item(ItemIdentifier)
    case downloads
    case settings
    case connections
}

/// Loading → onboarding (no signed-in connection) → main navigation.
struct WatchRootView: View {
    @State private var path: [WatchRoute] = []
    @State private var didAutoOpenPlayer = false

    private var data: HearthData { .shared }
    private var player: WatchPlayer { .shared }

    var body: some View {
        Group {
            if !data.connections.isLoaded {
                ProgressView()
            } else if data.connections.signedInConnections.isEmpty {
                OnboardingView()
            } else {
                NavigationStack(path: $path) {
                    HomeView()
                        .watchDestinations()
                }
                .onAppear(perform: autoOpenPlayer)
                .onChange(of: player.isActive) { _, _ in autoOpenPlayer() }
                #if DEBUG
                .task(id: WatchLifecycle.shared.isBootstrapped) {
                    guard WatchLifecycle.shared.isBootstrapped, let debugPath = await DebugLogin.initialPath() else { return }
                    didAutoOpenPlayer = true
                    path = debugPath
                }
                #endif
            }
        }
        .alert(
            player.alert?.title ?? "",
            isPresented: Binding(get: { player.alert != nil }, set: { if !$0 { player.alert = nil } }),
            presenting: player.alert
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            if let message = alert.message {
                Text(message)
            }
        }
        .alert(
            String(localized: "iPhone"),
            isPresented: Binding(get: { PhoneLink.shared.commandFailure != nil }, set: { if !$0 { PhoneLink.shared.commandFailure = nil } }),
            presenting: PhoneLink.shared.commandFailure
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure.localizedDescription)
        }
        .onOpenURL(perform: open)
    }

    /// Ten-second rule: when something is playing at launch, start on the player.
    private func autoOpenPlayer() {
        guard !didAutoOpenPlayer, player.isActive, path.isEmpty else { return }
        didAutoOpenPlayer = true
        path = [.nowPlaying]
    }

    /// `hearth://nowplaying[/<identifier>]`, `hearth://item/<identifier>`, `hearth://home` (complications).
    private func open(_ url: URL) {
        guard url.scheme == "hearth" else { return }
        let value = url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let id = value.isEmpty ? nil : ItemIdentifier(value.removingPercentEncoding ?? value)
        switch url.host() {
        case "nowplaying":
            // The complication's item may no longer be in the player (stopped, app relaunched): show its detail.
            if player.isActive {
                path = [.nowPlaying]
            } else {
                path = id.map { [.item($0)] } ?? []
            }
        case "item":
            if let id {
                path = player.itemID == id ? [.nowPlaying] : [.item(id)]
            }
        case "home":
            path = []
        default:
            break
        }
    }
}

extension View {
    /// All navigation destinations of the watch app.
    func watchDestinations() -> some View {
        navigationDestination(for: WatchRoute.self) { route in
            switch route {
            case .nowPlaying: NowPlayingScreen()
            case .playerOptions: PlayerOptionsView()
            case .chapters: ChaptersView()
            case .playbackSpeed: PlaybackSpeedView()
            case .sleepTimer: SleepTimerView()
            case .scrub: ScrubView()
            case .listenNow: ListenNowView()
            case .library(let id): LibraryView(libraryID: id)
            case .audiobooks(let id): AudiobooksView(libraryID: id)
            case .series(let id): SeriesListView(libraryID: id)
            case .authors(let id): AuthorsView(libraryID: id)
            case .podcasts(let id): PodcastsView(libraryID: id)
            case .item(let id): ItemDestinationView(id: id)
            case .downloads: DownloadsView()
            case .settings: WatchSettingsView()
            case .connections: ConnectionsView()
            }
        }
    }
}

/// Picks the detail screen for an identifier.
struct ItemDestinationView: View {
    let id: ItemIdentifier

    var body: some View {
        switch id.kind {
        case .audiobook, .episode: ItemDetailView(id: id)
        case .series: SeriesDetailView(id: id)
        case .author: AuthorDetailView(id: id)
        case .podcast: PodcastDetailView(id: id)
        case .narrator, .collection, .playlist:
            ContentUnavailableView("Not Available on Apple Watch", systemImage: "applewatch.slash")
        }
    }
}
