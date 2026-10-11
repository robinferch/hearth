import HearthData
import HearthIntents
import HearthModel
import HearthUI
import SwiftUI
import WidgetKit

struct ListenNowEntry: TimelineEntry {
    let date: Date
    let items: [WidgetItem]
    let nowPlayingID: ItemIdentifier?
    let isPlaying: Bool
    let tint: TintColor
}

struct ListenNowProvider: TimelineProvider {
    func placeholder(in context: Context) -> ListenNowEntry {
        ListenNowEntry(date: .now, items: Array(repeating: .placeholder, count: 6), nowPlayingID: nil, isPlaying: false, tint: .hearth)
    }

    func getSnapshot(in context: Context, completion: @escaping (ListenNowEntry) -> Void) {
        let entry = makeEntry()
        completion(context.isPreview && entry.items.isEmpty ? placeholder(in: context) : entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ListenNowEntry>) -> Void) {
        completion(Timeline(entries: [makeEntry()], policy: .after(.now.addingTimeInterval(60 * 60))))
    }

    private func makeEntry() -> ListenNowEntry {
        let snapshot = WidgetData.snapshot()
        var entries = snapshot.listenNow
        // The playing item first, with its live progress.
        if let nowPlaying = snapshot.nowPlaying {
            entries.removeAll { $0.id == nowPlaying.id }
            entries.insert(nowPlaying, at: 0)
        }
        return ListenNowEntry(
            date: .now,
            items: entries.prefix(8).map(WidgetItem.init),
            nowPlayingID: snapshot.nowPlaying?.id,
            isPlaying: snapshot.isPlaying,
            tint: snapshot.tint
        )
    }
}

struct ListenNowWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.listenNow, provider: ListenNowProvider()) { entry in
            ListenNowWidgetView(entry: entry)
                .widgetTint(entry.tint)
                .hearthWidgetBackground()
        }
        .configurationDisplayName("Listen Now")
        .description("The audiobooks and episodes you're listening to.")
        .supportedFamilies([.systemMedium, .systemLarge, .systemExtraLarge])
    }
}

struct ListenNowWidgetView: View {
    let entry: ListenNowEntry

    @Environment(\.widgetFamily) private var family

    private var rowCount: Int {
        switch family {
        case .systemMedium: 2
        case .systemExtraLarge: 8
        default: 6
        }
    }

    private var columns: Int { family == .systemExtraLarge ? 2 : 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemMedium ? 6 : 8) {
            header
            if entry.items.isEmpty {
                Spacer()
                Text("Start an audiobook or episode in Hearth and it shows up here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                Spacer()
            } else {
                let items = Array(entry.items.prefix(rowCount))
                if columns == 2 {
                    let half = Int((Double(items.count) / 2).rounded(.up))
                    HStack(alignment: .top, spacing: 16) {
                        rows(Array(items.prefix(half)))
                        rows(Array(items.dropFirst(half)))
                    }
                } else {
                    rows(items)
                }
                Spacer(minLength: 0)
            }
        }
        .widgetURL(WidgetData.url(host: "listen-now"))
    }

    private var header: some View {
        HStack {
            Text("Listen Now")
                .font(.headline)
                .foregroundStyle(.tint)
            Spacer()
            Image(systemName: "headphones")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
        }
    }

    private func rows(_ items: [WidgetItem]) -> some View {
        VStack(alignment: .leading, spacing: family == .systemMedium ? 6 : 8) {
            ForEach(items, id: \.id) { item in
                row(item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func row(_ item: WidgetItem) -> some View {
        let isCurrent = item.id == entry.nowPlayingID
        return HStack(spacing: 10) {
            Link(destination: item.url) {
                HStack(spacing: 10) {
                    WidgetCover(data: item.coverData, cornerRadius: 6, symbol: item.id.kind == .episode ? "antenna.radiowaves.left.and.right" : "book.closed")
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            if item.isDownloaded {
                                DownloadedBadge()
                            }
                            if let detail = item.detailLine {
                                Text(detail)
                                    .lineLimit(1)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            ProgressPlayButton(item: item, isCurrent: isCurrent, isPlaying: isCurrent && entry.isPlaying, size: 32)
        }
    }
}
