import HearthData
import HearthModel
import HearthPlayback
import HearthUI
import SwiftUI

/// Root list: now playing, Listen Now, libraries, downloads, settings.
struct HomeView: View {
    @State private var listenNow: [AnyPlayableItem] = []
    @State private var didLoad = false

    private var data: HearthData { .shared }
    private var player: WatchPlayer { .shared }

    private static let listenNowLimit = 5

    var body: some View {
        List {
            if player.isActive {
                Section {
                    NavigationLink(value: WatchRoute.nowPlaying) {
                        NowPlayingCard()
                    }
                }
            } else if let resume = resumeItem {
                Section {
                    Button {
                        Task { await player.resumeLastPlayed() }
                    } label: {
                        ResumeCard(item: resume)
                    }
                }
            }

            if data.connections.isOffline {
                Section {
                    Label("Offline – showing downloads", systemImage: "icloud.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Listen Now") {
                NavigationLink(value: WatchRoute.listenNow) {
                    ListenedTodaySummary()
                }
                if !didLoad {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(listenNow.prefix(Self.listenNowLimit)) { item in
                        NavigationLink(value: WatchRoute.item(item.id)) {
                            WatchItemRow(item: item)
                        }
                    }
                    if listenNow.count > Self.listenNowLimit {
                        NavigationLink(value: WatchRoute.listenNow) {
                            Text("Show All")
                        }
                    }
                }
            }

            if !data.connections.allLibraries.isEmpty, !data.connections.isOffline {
                Section("Libraries") {
                    ForEach(data.connections.allLibraries) { library in
                        NavigationLink(value: WatchRoute.library(library.id)) {
                            Label(library.name, systemImage: library.systemImage)
                        }
                    }
                }
            }

            Section {
                NavigationLink(value: WatchRoute.downloads) {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }
                NavigationLink(value: WatchRoute.settings) {
                    Label("Settings", systemImage: "gear")
                }
            }
        }
        .navigationTitle("Hearth")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if player.isActive {
                    NavigationLink(value: WatchRoute.nowPlaying) {
                        Image(systemName: player.isPlaying ? "waveform" : "play.fill")
                            .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                    }
                    .accessibilityLabel("Now Playing")
                }
            }
        }
        .task(id: data.isBootstrapped) {
            await loadListenNow()
        }
        .refreshable {
            await data.refresh()
            await loadListenNow()
        }
    }

    private var resumeItem: AnyPlayableItem? {
        guard let id = AudioPlayer.shared.lastPlayedItemID else { return nil }
        return listenNow.first { $0.id == id }
    }

    private func loadListenNow() async {
        listenNow = await data.items.listenNow()
        didLoad = true
    }
}

/// Item currently playing (watch or iPhone).
struct NowPlayingCard: View {
    private var player: WatchPlayer { .shared }

    var body: some View {
        HStack(spacing: 8) {
            ItemImage(id: player.itemID, size: .tiny, cornerRadius: 6)
                .frame(width: 40, height: 40)
                .overlay(alignment: .bottomTrailing) {
                    if player.isPlaying {
                        Image(systemName: "waveform")
                            .font(.caption2.weight(.bold))
                            .symbolEffect(.variableColor.iterative, isActive: true)
                            .padding(3)
                            .background(.black.opacity(0.6), in: .circle)
                            .offset(x: 4, y: 4)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Label(player.mode == .phone ? "On iPhone" : "Now Playing", systemImage: player.mode == .phone ? "iphone" : "applewatch")
                    .font(.caption2)
                    .foregroundStyle(.tint)
                    .labelStyle(.titleAndIcon)
                Text(player.chapterTitle ?? player.title)
                    .font(.headline)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// "Resume" shortcut for the last played item.
private struct ResumeCard: View {
    let item: AnyPlayableItem

    var body: some View {
        HStack(spacing: 8) {
            ItemImage(id: item.id, size: .tiny, cornerRadius: 6)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Label("Resume", systemImage: "play.fill")
                    .font(.caption2)
                    .foregroundStyle(.tint)
                Text(item.name)
                    .font(.headline)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Full Listen Now list.
struct ListenNowView: View {
    @State private var items: [AnyPlayableItem] = []
    @State private var didLoad = false

    var body: some View {
        Group {
            if items.isEmpty {
                if didLoad {
                    ContentUnavailableView("Nothing in Progress", systemImage: "books.vertical")
                } else {
                    ProgressView()
                }
            } else {
                List {
                    Section {
                        ListenedTodaySummary()
                    }
                    ForEach(items) { item in
                        NavigationLink(value: WatchRoute.item(item.id)) {
                            WatchItemRow(item: item)
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                Task { await WatchPlayer.shared.playLocally(item.id, origin: .listenNow) }
                            } label: {
                                Label("Play", systemImage: "play.fill")
                            }
                            .tint(.accentColor)
                        }
                    }
                }
            }
        }
        .navigationTitle("Listen Now")
        .task {
            items = await HearthData.shared.items.listenNow()
            didLoad = true
        }
    }
}

/// Today's listening time vs the daily goal.
private struct ListenedTodaySummary: View {
    var body: some View {
        let listened = HearthData.shared.listening.listenedToday
        let goal = AppSettings.shared.dailyGoalMinutes
        HStack(spacing: 10) {
            ListenedTodayGauge(listened: listened, goalMinutes: goal, lineWidth: 4)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading) {
                Text("Listened Today")
                    .font(.headline)
                Text("\(Int(listened / 60)) of \(goal) min")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
