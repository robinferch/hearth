import HearthData
import HearthModel
import HearthUI
import SwiftUI

/// Downloads on the watch: in progress, audiobooks, episodes; storage used; remove all.
struct DownloadsView: View {
    @State private var storageUsed: Int64?
    @State private var confirmsRemoveAll = false

    private var downloads: DownloadManager { HearthData.shared.downloads }

    var body: some View {
        let active = downloads.activeDownloadIDs
        let audiobooks = downloads.downloadedAudiobooks()
        let episodes = downloads.downloadedEpisodes()

        List {
            Section {
                LabeledContent("Storage Used") {
                    if let storageUsed {
                        Text(HearthFormat.bytes(storageUsed))
                    } else {
                        ProgressView()
                    }
                }
            }

            if !active.isEmpty {
                Section("Downloading") {
                    ForEach(active, id: \.self) { id in
                        DownloadingRow(id: id)
                    }
                }
            }

            if !audiobooks.isEmpty {
                Section("Audiobooks") {
                    ForEach(audiobooks) { audiobook in
                        NavigationLink(value: WatchRoute.item(audiobook.id)) {
                            WatchItemRow(audiobook: audiobook)
                        }
                    }
                    .onDelete { offsets in
                        remove(offsets.map { audiobooks[$0].id })
                    }
                }
            }

            if !episodes.isEmpty {
                Section("Episodes") {
                    ForEach(episodes) { episode in
                        NavigationLink(value: WatchRoute.item(episode.id)) {
                            WatchItemRow(id: episode.id, title: episode.name, subtitle: episode.podcastName)
                        }
                    }
                    .onDelete { offsets in
                        remove(offsets.map { episodes[$0].id })
                    }
                }
            }

            if audiobooks.isEmpty, episodes.isEmpty, active.isEmpty {
                Section {
                    Text("Download audiobooks and episodes to listen without your iPhone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    Button("Remove All Downloads", role: .destructive) {
                        confirmsRemoveAll = true
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        .task(id: audiobooks.count + episodes.count) {
            storageUsed = await downloads.storageUsed()
        }
        .confirmationDialog("Remove all downloads from this watch?", isPresented: $confirmsRemoveAll, titleVisibility: .visible) {
            Button("Remove All", role: .destructive) {
                Task {
                    await downloads.removeAll()
                    storageUsed = await downloads.storageUsed()
                }
            }
        }
    }

    private func remove(_ ids: [ItemIdentifier]) {
        Task {
            for id in ids {
                await downloads.remove(id)
            }
            storageUsed = await downloads.storageUsed()
        }
    }
}

private struct DownloadingRow: View {
    let id: ItemIdentifier
    @State private var item: AnyPlayableItem?

    var body: some View {
        let progress = HearthData.shared.downloads.progress(of: id)
        HStack(spacing: 8) {
            ItemImage(id: id, size: .tiny, cornerRadius: 5)
                .frame(width: 32, height: 32)
            Text(item?.name ?? String(localized: "Downloading…"))
                .font(.footnote)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Task { await HearthData.shared.downloads.cancel(id) }
            } label: {
                DownloadProgressRing(progress: progress, lineWidth: 2)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel Download")
            .accessibilityValue(HearthFormat.percent(progress))
        }
        .task {
            item = try? await HearthData.shared.items.playable(id)
        }
    }
}
