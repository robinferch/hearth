import CarPlay
import HearthData
import HearthModel
import HearthPlayback
import HearthUI
import UIKit

/// Creates item rows (cover, "authors • narrators", progress, now-playing indicator, downloaded accessory) and keeps
/// track of them so playback changes can update the indicators in place.
@MainActor
final class CarPlayRows {
    private final class WeakRow {
        weak var item: CPListItem?
        init(_ item: CPListItem) { self.item = item }
    }

    private var rows: [ItemIdentifier: [WeakRow]] = [:]
    private var images: [ItemIdentifier: UIImage] = [:]

    func removeAll() {
        rows.removeAll()
    }

    func row(for item: AnyPlayableItem, controller: CarPlayController, origin: PlaybackOrigin) -> CPListItem {
        let data = HearthData.shared
        let id = item.id
        let isDownloaded = data.downloads.status(of: id) == .completed
        let row = CPListItem(
            text: item.name,
            detailText: detail(for: item),
            image: images[id] ?? Self.placeholder(for: id.kind),
            accessoryImage: isDownloaded ? UIImage(systemName: "arrow.down.circle.fill") : nil,
            accessoryType: .none
        )
        if case .audiobook(let audiobook) = item {
            row.isExplicitContent = audiobook.explicit
        }
        row.playbackProgress = CGFloat(data.progress.progress(for: id)?.progress ?? 0)
        row.playingIndicatorLocation = .trailing
        row.isPlaying = AudioPlayer.shared.isCurrent(id) && AudioPlayer.shared.isPlaying
        row.userInfo = id.description
        row.handler = { [weak controller] _, completion in
            guard let controller else { return completion() }
            Task {
                await controller.play(id, origin: origin)
                completion()
            }
        }
        rows[id, default: []].append(WeakRow(row))
        loadImage(for: id, into: row)
        return row
    }

    /// `authors • narrators` (books) or `podcast • date` (episodes).
    private func detail(for item: AnyPlayableItem) -> String? {
        switch item {
        case .audiobook(let audiobook):
            let narrators = audiobook.narrators.isEmpty ? nil : audiobook.narrators.formatted(.list(type: .and, width: .short))
            let line = HearthFormat.joined([audiobook.authorLine, narrators])
            return line.isEmpty ? nil : line
        case .episode(let episode):
            let line = HearthFormat.joined([episode.podcastName, episode.publishedAt.map { HearthFormat.releaseDate($0) }])
            return line.isEmpty ? nil : line
        }
    }

    func loadImage(for id: ItemIdentifier, into row: CPListItem) {
        if let image = images[id] {
            row.setImage(image)
            return
        }
        Task {
            guard let data = await HearthData.shared.images.imageData(for: id, size: .small), let image = Self.scaled(data) else { return }
            images[id] = image
            row.setImage(image)
        }
    }

    /// Refreshes the now-playing indicator and progress of all live rows.
    func updatePlaybackState() {
        let player = AudioPlayer.shared
        let progress = HearthData.shared.progress
        for (id, entries) in rows {
            let live = entries.compactMap(\.item)
            if live.isEmpty {
                rows[id] = nil
                continue
            }
            let isPlaying = player.isCurrent(id) && player.isPlaying
            let value = CGFloat(progress.progress(for: id)?.progress ?? 0)
            for row in live {
                if row.isPlaying != isPlaying {
                    row.isPlaying = isPlaying
                }
                if abs(row.playbackProgress - value) > 0.005 {
                    row.playbackProgress = value
                }
            }
        }
    }

    static func placeholder(for kind: ItemIdentifier.Kind) -> UIImage? {
        let name = switch kind {
        case .podcast, .episode: "antenna.radiowaves.left.and.right"
        case .series: "books.vertical"
        case .collection, .playlist: "rectangle.stack"
        default: "book.closed"
        }
        return UIImage(systemName: name)
    }

    private static func scaled(_ data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        let maximum = CPListItem.maximumImageSize
        let scale = min(maximum.width / max(image.size.width, 1), maximum.height / max(image.size.height, 1), 1)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
