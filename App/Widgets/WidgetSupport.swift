import HearthData
import HearthIntents
import HearthModel
import HearthUI
import ImageIO
import SwiftUI
import UIKit
import WidgetKit

/// Widget kinds (also used by the app for targeted reloads).
enum WidgetKind {
    static let play = "me.robinferch.hearth.widget.play"
    static let listenNow = "me.robinferch.hearth.widget.listenNow"
    static let listenedToday = "me.robinferch.hearth.widget.listenedToday"
}

/// Everything a widget needs about one item, from the shared snapshot (or a configured entity).
struct WidgetItem: Hashable, Sendable {
    var id: ItemIdentifier
    var title: String
    var subtitle: String?
    var progress: Double
    var remaining: TimeInterval?
    var isDownloaded: Bool
    var coverData: Data?

    init(_ entry: SharedSnapshot.Entry) {
        id = entry.id
        title = entry.title
        subtitle = entry.subtitle
        progress = entry.progress
        remaining = entry.remaining
        isDownloaded = entry.isDownloaded
        coverData = entry.coverFile.flatMap(WidgetData.coverData)
    }

    init(id: ItemIdentifier, title: String, subtitle: String?, progress: Double, remaining: TimeInterval?, isDownloaded: Bool, coverData: Data?) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.progress = progress
        self.remaining = remaining
        self.isDownloaded = isDownloaded
        self.coverData = coverData
    }

    var entity: ItemEntity {
        ItemEntity(id: id, title: title, subtitle: subtitle)
    }

    var url: URL { WidgetData.url(host: "item", id: id) }

    static let placeholder = WidgetItem(
        id: ItemIdentifier(kind: .audiobook, connectionID: "placeholder", libraryID: "placeholder", primaryID: "placeholder"),
        title: String(localized: "The Hearth and the Hollow"),
        subtitle: String(localized: "Ada Winterbourne"),
        progress: 0.42,
        remaining: 3 * 3600 + 12 * 60,
        isDownloaded: true,
        coverData: nil
    )
}

enum WidgetData {
    static func snapshot() -> SharedSnapshot {
        SharedSnapshotStore.read()
    }

    static func coverData(_ file: String) -> Data? {
        try? Data(contentsOf: SharedSnapshotStore.coverURL(file))
    }

    static func url(host: String, id: ItemIdentifier? = nil) -> URL {
        var components = URLComponents()
        components.scheme = "hearth"
        components.host = host
        if let id {
            components.path = "/" + id.description
        }
        return components.url ?? URL(string: "hearth://")!
    }

    /// Listened today, reset when the snapshot is from an earlier day.
    static func listenedToday(_ snapshot: SharedSnapshot, at date: Date = .now) -> TimeInterval {
        Calendar.current.isDate(snapshot.updatedAt, inSameDayAs: date) ? snapshot.listenedToday : 0
    }

    /// Decodes a small thumbnail (widgets have tight memory limits).
    static func image(_ data: Data?, maxPixelSize: Int = 300) -> UIImage? {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

// MARK: - Views

struct WidgetCover: View {
    let data: Data?
    var cornerRadius: CGFloat = 8
    var symbol = "book.closed"

    var body: some View {
        Group {
            if let image = WidgetData.image(data) {
                Image(uiImage: image)
                    .resizable()
                    .widgetAccentedRenderingMode(.desaturated)
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(.tint.opacity(0.2))
                    Image(systemName: symbol)
                        .font(.title2)
                        .foregroundStyle(.tint)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Circular play/pause button whose ring shows the item's progress.
struct ProgressPlayButton: View {
    let item: WidgetItem
    let isCurrent: Bool
    let isPlaying: Bool
    var size: CGFloat = 44

    var body: some View {
        Group {
            if isCurrent {
                Button(intent: TogglePlaybackIntent()) { label }
            } else {
                Button(intent: PlayItemIntent(item: item.entity)) { label }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCurrent && isPlaying ? Text("Pause") : Text("Play"))
    }

    private var label: some View {
        ZStack {
            Circle()
                .fill(.tint.opacity(0.18))
            Circle()
                .trim(from: 0, to: min(max(item.progress, 0), 1))
                .stroke(.tint, style: StrokeStyle(lineWidth: max(2, size / 14), lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(max(1, size / 28))
            Image(systemName: isCurrent && isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(.tint)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: size, height: size)
    }
}

struct DownloadedBadge: View {
    var body: some View {
        Image(systemName: "arrow.down.circle.fill")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("Downloaded"))
    }
}

extension WidgetItem {
    /// `3h 12m left` or the subtitle.
    var detailLine: String? {
        if let remaining, remaining > 0, progress > 0 {
            return HearthFormat.remaining(remaining)
        }
        return subtitle
    }
}

extension View {
    /// Applies the user's tint from the snapshot.
    func widgetTint(_ tint: TintColor) -> some View {
        self.tint(tint.color)
    }
}

/// System widgets get the standard fill; accessory (Lock Screen / StandBy) widgets stay transparent.
private struct HearthWidgetBackground: ViewModifier {
    @Environment(\.widgetFamily) private var family

    func body(content: Content) -> some View {
        content.containerBackground(for: .widget) {
            switch family {
            case .accessoryCircular, .accessoryRectangular, .accessoryInline:
                Color.clear
            default:
                Rectangle().fill(.fill.tertiary)
            }
        }
    }
}

extension View {
    func hearthWidgetBackground() -> some View {
        modifier(HearthWidgetBackground())
    }
}
