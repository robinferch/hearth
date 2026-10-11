import HearthData
import HearthModel
import HearthPlayback
import HearthUI
import SwiftUI

/// Offline mode: downloaded audiobooks (by progress) and a section per downloaded podcast.
struct OfflineView: View {
    @Environment(Navigator.self) private var navigator
    @Environment(PlayerPresentation.self) private var player
    @Environment(\.playerNamespace) private var playerNamespace

    @State private var isGoingOnline = false

    private var downloads: DownloadManager { HearthData.shared.downloads }

    var body: some View {
        @Bindable var navigator = navigator
        @Bindable var player = player

        NavigationStack(path: navigator.path(for: .noLibrary)) {
            content
                .navigationTitle("Offline")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            navigator.sheet = .settings
                        } label: {
                            Label("Settings", systemImage: "gear")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        ListenedTodayButton()
                    }
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            isGoingOnline = true
                            Task {
                                await HearthData.shared.connections.setOffline(false)
                                isGoingOnline = false
                            }
                        } label: {
                            if isGoingOnline {
                                ProgressView()
                            } else {
                                Label("Go Online", systemImage: "icloud")
                                    .labelStyle(.titleAndIcon)
                            }
                        }
                        .buttonStyle(.glassProminent)
                    }
                }
                .hearthNavigationDestinations()
        }
        .safeAreaInset(edge: .bottom) {
            if AudioPlayer.shared.currentItem != nil || AudioPlayer.shared.lastPlayedItemID != nil {
                MiniPlayerView()
                    .frame(height: 56)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }
        }
        .fullScreenCover(isPresented: $player.isExpanded) {
            NowPlayingView()
                .sceneAlertHost()
                .modifier(ZoomTransition(sourceID: PlayerPresentation.transitionSourceID, namespace: playerNamespace))
        }
    }

    @ViewBuilder
    private var content: some View {
        let books = downloads.downloadedAudiobooks().sorted { progress(of: $0.id) > progress(of: $1.id) }
        let podcasts = downloads.downloadedPodcasts()
        if books.isEmpty, podcasts.isEmpty {
            ContentUnavailableView {
                Label("You're Offline", systemImage: "icloud.slash")
            } description: {
                Text("Downloaded audiobooks and episodes appear here. Go online to browse your libraries.")
            } actions: {
                Button("Go Online") {
                    Task { await HearthData.shared.connections.setOffline(false) }
                }
                .buttonStyle(.glassProminent)
            }
        } else {
            List {
                if !books.isEmpty {
                    Section("Audiobooks") {
                        ForEach(books) { book in
                            NavigationLink(value: NavigationDestination.item(book.id)) {
                                AudiobookRow(audiobook: book)
                            }
                            .itemActions(for: .audiobook(book))
                        }
                    }
                }
                ForEach(podcasts) { podcast in
                    Section(podcast.name) {
                        ForEach(downloads.downloadedEpisodes(podcast: podcast.id)) { episode in
                            NavigationLink(value: NavigationDestination.item(episode.id)) {
                                EpisodeRow(episode: episode, showsCover: false, descriptionLines: 1, context: .podcastPage)
                            }
                            .itemActions(for: .episode(episode), context: .podcastPage)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func progress(of id: ItemIdentifier) -> Double {
        HearthData.shared.progress.progress(for: id)?.progress ?? 0
    }
}

/// Applies `.navigationTransition(.zoom)` when a namespace is available.
struct ZoomTransition: ViewModifier {
    let sourceID: String
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            content
        }
    }
}

/// Shown when a connection can't be reached: countdown to offline mode (7 s) + retry.
struct ConnectionFailureView: View {
    let connectionID: ConnectionID?

    @State private var remaining = 7
    @State private var isRetrying = false

    private var connections: ConnectionStore { HearthData.shared.connections }

    /// All connections are unreachable → automatically go offline after the countdown.
    private var allFailed: Bool {
        !connections.connections.isEmpty && connections.connections.allSatisfy { connections.status[$0.id] == .offline }
    }

    var body: some View {
        ContentUnavailableView {
            Label("Can't Reach Server", systemImage: "wifi.exclamationmark")
        } description: {
            VStack(spacing: 6) {
                if let connectionID, let connection = connections.connection(connectionID) {
                    Text(connection.host.host() ?? connection.host.absoluteString)
                }
                Text("Make sure Hearth can reach your server.")
                if allFailed, !isRetrying {
                    Text("Going offline in \(remaining) s")
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                        .foregroundStyle(.secondary)
                }
            }
        } actions: {
            HStack {
                Button {
                    retry()
                } label: {
                    if isRetrying {
                        ProgressView()
                    } else {
                        Text("Retry")
                    }
                }
                .buttonStyle(.glassProminent)
                Button("Go Offline") {
                    Task { await connections.setOffline(true) }
                }
                .buttonStyle(.glass)
            }
        }
        .task(id: isRetrying) {
            guard allFailed, !isRetrying else { return }
            remaining = 7
            while remaining > 0 {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                withAnimation { remaining -= 1 }
            }
            if allFailed {
                await connections.setOffline(true)
            }
        }
    }

    private func retry() {
        isRetrying = true
        Task {
            await connections.retryOffline()
            isRetrying = false
        }
    }
}
