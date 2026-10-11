import AppIntents
import HearthData
import HearthIntents
import HearthModel
import HearthUI
import SwiftUI
import WidgetKit

/// Configuration of the Play widget: an item, or "automatic" (now playing / first Listen Now item).
struct PlayWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Play"
    static let description = IntentDescription("Play an audiobook or episode. Leave empty to show what you're listening to.")

    @Parameter(title: "Item")
    var item: ItemEntity?
}

struct PlayEntry: TimelineEntry {
    let date: Date
    let item: WidgetItem?
    /// The entry's item is loaded in the player.
    let isCurrent: Bool
    let isPlaying: Bool
    let tint: TintColor
}

struct PlayProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PlayEntry {
        PlayEntry(date: .now, item: .placeholder, isCurrent: false, isPlaying: false, tint: .hearth)
    }

    func snapshot(for configuration: PlayWidgetConfiguration, in context: Context) async -> PlayEntry {
        if context.isPreview, WidgetData.snapshot().listenNow.isEmpty, configuration.item == nil {
            return placeholder(in: context)
        }
        return await entry(for: configuration)
    }

    func timeline(for configuration: PlayWidgetConfiguration, in context: Context) async -> Timeline<PlayEntry> {
        // The app reloads timelines whenever the snapshot changes; refresh occasionally as a fallback.
        Timeline(entries: [await entry(for: configuration)], policy: .after(.now.addingTimeInterval(30 * 60)))
    }

    private func entry(for configuration: PlayWidgetConfiguration) async -> PlayEntry {
        let snapshot = WidgetData.snapshot()
        let nowPlayingID = snapshot.nowPlaying?.id
        let item: WidgetItem?
        if let entity = configuration.item, let id = entity.itemID {
            if let entry = snapshot.nowPlaying, entry.id == id {
                item = WidgetItem(entry)
            } else if let entry = snapshot.listenNow.first(where: { $0.id == id }) {
                item = WidgetItem(entry)
            } else {
                item = await Self.item(for: entity, id: id)
            }
        } else {
            item = (snapshot.nowPlaying ?? snapshot.listenNow.first).map(WidgetItem.init)
        }
        let isCurrent = item != nil && item?.id == nowPlayingID
        return PlayEntry(date: .now, item: item, isCurrent: isCurrent, isPlaying: isCurrent && snapshot.isPlaying, tint: snapshot.tint)
    }

    /// A configured item that isn't part of the snapshot: progress and download state from the local database.
    @MainActor
    private static func item(for entity: ItemEntity, id: ItemIdentifier) -> WidgetItem {
        let data = HearthData.shared
        let progress = data.progress.progress(for: id)
        return WidgetItem(
            id: id,
            title: entity.title,
            subtitle: entity.subtitle,
            progress: progress?.progress ?? 0,
            remaining: progress?.remaining,
            isDownloaded: data.downloads.status(of: id) == .completed,
            coverData: entity.imageData
        )
    }
}

struct PlayWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetKind.play, intent: PlayWidgetConfiguration.self, provider: PlayProvider()) { entry in
            PlayWidgetView(entry: entry)
                .widgetTint(entry.tint)
                .hearthWidgetBackground()
        }
        .configurationDisplayName("Play")
        .description("Continue an audiobook or episode right from your Home Screen.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

struct PlayWidgetView: View {
    let entry: PlayEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let item = entry.item {
            content(item)
                .widgetURL(item.url)
        } else {
            empty
        }
    }

    @ViewBuilder
    private func content(_ item: WidgetItem) -> some View {
        switch family {
        case .accessoryCircular:
            ProgressPlayButton(item: item, isCurrent: entry.isCurrent, isPlaying: entry.isPlaying, size: 52)
                .widgetAccentable()
        case .accessoryRectangular:
            rectangular(item)
        case .systemMedium:
            medium(item)
        default:
            small(item)
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "headphones")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("Nothing to play")
                .font(.footnote.weight(.semibold))
            if family != .accessoryCircular {
                Text("Start listening in Hearth.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .widgetURL(WidgetData.url(host: "listen-now"))
    }

    private func small(_ item: WidgetItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                WidgetCover(data: item.coverData, cornerRadius: 10, symbol: symbol(item))
                    .frame(width: 62, height: 62)
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                Spacer(minLength: 4)
                VStack(spacing: 6) {
                    ProgressPlayButton(item: item, isCurrent: entry.isCurrent, isPlaying: entry.isPlaying, size: 40)
                    secondaryButton(item, size: 28)
                }
            }
            Spacer(minLength: 0)
            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            HStack(spacing: 4) {
                if item.isDownloaded {
                    DownloadedBadge()
                }
                if let detail = item.detailLine {
                    Text(detail)
                        .lineLimit(1)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func medium(_ item: WidgetItem) -> some View {
        HStack(spacing: 14) {
            WidgetCover(data: item.coverData, cornerRadius: 12, symbol: symbol(item))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.isCurrent ? (entry.isPlaying ? "Now Playing" : "Paused") : "Continue Listening")
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.tint)
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    if item.isDownloaded {
                        DownloadedBadge()
                    }
                    if let remaining = item.remaining, remaining > 0, item.progress > 0 {
                        Text(HearthFormat.remaining(remaining))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    ProgressPlayButton(item: item, isCurrent: entry.isCurrent, isPlaying: entry.isPlaying, size: 40)
                    secondaryButton(item, size: 32)
                    if entry.isCurrent, entry.isPlaying, item.id.kind == .audiobook {
                        Button(intent: CreateBookmarkIntent()) {
                            circleIcon("bookmark.fill", size: 32)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Create Bookmark"))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func rectangular(_ item: WidgetItem) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)
                if let detail = item.detailLine {
                    Text(detail)
                        .font(.caption)
                        .lineLimit(1)
                }
                ProgressView(value: min(max(item.progress, 0), 1))
                    .progressViewStyle(.linear)
                    .widgetAccentable()
            }
            ProgressPlayButton(item: item, isCurrent: entry.isCurrent, isPlaying: entry.isPlaying, size: 36)
                .widgetAccentable()
        }
    }

    /// Skip back while playing, else nothing (keeps the small layout calm).
    @ViewBuilder
    private func secondaryButton(_ item: WidgetItem, size: CGFloat) -> some View {
        if entry.isCurrent, entry.isPlaying {
            Button(intent: SkipBackwardIntent(seconds: nil)) {
                circleIcon("gobackward", size: size)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Skip Backward"))
        }
    }

    private func circleIcon(_ name: String, size: CGFloat) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.tint)
            .frame(width: size, height: size)
            .background(.tint.opacity(0.12), in: Circle())
    }

    private func symbol(_ item: WidgetItem) -> String {
        item.id.kind == .episode ? "antenna.radiowaves.left.and.right" : "book.closed"
    }
}
