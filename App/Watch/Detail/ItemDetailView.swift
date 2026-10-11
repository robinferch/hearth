import HearthAPI
import HearthData
import HearthModel
import HearthPlayback
import HearthUI
import SwiftUI
import WatchKit

/// Audiobook / episode detail: cover, metadata, play (watch or iPhone), download, finished state.
struct ItemDetailView: View {
    let id: ItemIdentifier

    var body: some View {
        AsyncContent {
            try await HearthData.shared.items.playable(id)
        } content: { item in
            ItemDetailContent(item: item)
        }
    }
}

private struct ItemDetailContent: View {
    let item: AnyPlayableItem

    @State private var confirmsRemoval = false
    @State private var actionError: String?

    private var player: WatchPlayer { .shared }
    private var data: HearthData { .shared }

    var body: some View {
        let status = ItemStatus.of(item.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header(status: status)
                playButtons(status: status)
                downloadButton(status: status)
                finishedButton(status: status)
                if let actionError {
                    Text(actionError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                details
            }
            .scenePadding(.horizontal)
        }
        .navigationTitle(item.base.subtitleLine ?? item.name)
        .navigationBarTitleDisplayMode(.inline)
        .containerBackground(for: .navigation) {
            DominantColorReader(id: item.id) { color in
                DominantColorGradient(color: color)
            }
        }
        .confirmationDialog("Remove Download?", isPresented: $confirmsRemoval) {
            Button("Remove", role: .destructive) {
                Task { await data.downloads.remove(item.id) }
            }
        }
    }

    // MARK: Sections

    private func header(status: ItemStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ItemImage(id: item.id, size: .small, cornerRadius: 8)
                .frame(width: 76, height: 76)
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            Text(item.name)
                .font(.headline)
                .lineLimit(4)
            if let subtitle = authorsLine {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if status.isInProgress {
                ProgressCapsule(progress: status.fraction, height: 4)
                Text(HearthFormat.remaining(status.remaining(duration: item.duration), rate: ItemStatus.effectiveRate(for: item.id)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if status.isFinished {
                Label(HearthFormat.finished(status.progress?.finishedAt), systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            } else if item.duration > 0 {
                Text(HearthFormat.duration(item.duration))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var authorsLine: String? {
        switch item {
        case .audiobook(let audiobook): audiobook.authorLine
        case .episode(let episode): episode.podcastName
        }
    }

    @ViewBuilder
    private func playButtons(status: ItemStatus) -> some View {
        let isCurrentLocal = AudioPlayer.shared.isCurrent(item.id)
        Button {
            Task { await player.playLocally(item.id) }
        } label: {
            if player.isStarting {
                ProgressView()
            } else {
                Label(playTitle(status: status, isCurrent: isCurrentLocal), systemImage: isCurrentLocal && AudioPlayer.shared.isPlaying ? "pause.fill" : "play.fill")
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(status.isDownloading || player.isStarting)

        if PhoneLink.shared.isReachable {
            Button {
                Task { await player.playOnPhone(item.id) }
            } label: {
                Label("Play on iPhone", systemImage: "iphone")
            }
            .buttonStyle(.bordered)
        }
    }

    private func playTitle(status: ItemStatus, isCurrent: Bool) -> String {
        if isCurrent {
            return AudioPlayer.shared.isPlaying ? String(localized: "Pause") : String(localized: "Resume")
        }
        if status.isFinished {
            return String(localized: "Listen Again")
        }
        return status.isInProgress ? String(localized: "Resume") : String(localized: "Play")
    }

    @ViewBuilder
    private func downloadButton(status: ItemStatus) -> some View {
        switch status.download {
        case .completed:
            Button(role: .destructive) {
                confirmsRemoval = true
            } label: {
                Label("Remove Download", systemImage: "trash")
            }
            .buttonStyle(.bordered)
        case .downloading:
            Button {
                Task { await data.downloads.cancel(item.id) }
            } label: {
                HStack {
                    DownloadProgressRing(progress: status.downloadProgress, lineWidth: 2.5)
                        .frame(width: 20, height: 20)
                    Text("Cancel Download")
                }
            }
            .buttonStyle(.bordered)
        case .none:
            Button {
                Task { await download() }
            } label: {
                Label("Download to Watch", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
            .disabled(data.connections.isOffline)
        }
    }

    private func finishedButton(status: ItemStatus) -> some View {
        Button {
            Task { await setFinished(!status.isFinished) }
        } label: {
            if status.isFinished {
                Label("Mark as Unfinished", systemImage: "arrow.uturn.backward.circle")
            } else {
                Label("Mark as Finished", systemImage: "checkmark.circle")
            }
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch item {
            case .audiobook(let audiobook):
                if let series = audiobook.series.first {
                    detailLine("Series", series.formatted)
                }
                if !audiobook.narrators.isEmpty {
                    detailLine("Narrated by", audiobook.narrators.formatted(.list(type: .and, width: .short)))
                }
                if let year = HearthFormat.year(from: audiobook.released) {
                    detailLine("Published", year)
                }
            case .episode(let episode):
                if let date = episode.publishedAt {
                    detailLine("Released", HearthFormat.releaseDate(date))
                }
            }
            if item.duration > 0 {
                detailLine("Duration", HearthFormat.duration(item.duration))
            }
            if let description = HearthFormat.plainText(fromHTML: item.base.descriptionHTML), !description.isEmpty {
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
                    .padding(.top, 4)
            }
        }
        .padding(.top, 4)
    }

    private func detailLine(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.footnote)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Actions

    private func download() async {
        actionError = nil
        do {
            try await data.downloads.download(item.id)
            WKInterfaceDevice.current().play(.click)
        } catch DownloadError.cellularNotAllowed {
            actionError = String(localized: "Downloads over cellular are turned off in Settings.")
        } catch {
            actionError = String(localized: "The download couldn't be started.")
        }
    }

    private func setFinished(_ finished: Bool) async {
        actionError = nil
        do {
            try await AudioPlayer.shared.setFinished(item.id, finished: finished)
            WKInterfaceDevice.current().play(.success)
        } catch {
            actionError = String(localized: "The progress couldn't be updated.")
        }
    }
}
