import HearthData
import HearthUI
import SwiftUI
import WidgetKit

/// Now playing (watch or iPhone) or the item to resume: progress with cover, title, chapter.
struct NowPlayingComplication: Widget {
    static let kind = "me.robinferch.hearth.watch.nowPlaying"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider(relevance: NowPlayingRelevance.score)) { entry in
            NowPlayingComplicationView(entry: entry)
                .containerBackground(entry.tint.gradient.opacity(0.35), for: .widget)
                .widgetURL(entry.url)
        }
        .configurationDisplayName("Now Playing")
        .description("Shows what's playing in Hearth, or what to resume.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryCorner, .accessoryInline])
    }
}

struct NowPlayingComplicationView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let item = entry.item {
            switch family {
            case .accessoryCircular: circular(item)
            case .accessoryCorner: corner(item)
            case .accessoryInline: inline(item)
            default: rectangular(item)
            }
        } else {
            empty
        }
    }

    // MARK: Families

    private func circular(_ item: SharedSnapshot.Entry) -> some View {
        Gauge(value: item.progress) {
            Image(systemName: "book.closed")
        } currentValueLabel: {
            coverOrSymbol(size: 34)
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(entry.tint)
        .accessibilityLabel(accessibilityLabel(item))
    }

    private func rectangular(_ item: SharedSnapshot.Entry) -> some View {
        HStack(spacing: 6) {
            coverOrSymbol(size: 42)
                .clipShape(.rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Label(statusTitle, systemImage: entry.isPlaying ? "waveform" : "play.fill")
                    .font(.caption2)
                    .foregroundStyle(entry.tint)
                    .widgetAccentable()
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)
                if let line = entry.isNowPlaying ? (entry.snapshot.chapterTitle ?? item.subtitle) : item.subtitle {
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                ProgressView(value: item.progress)
                    .tint(entry.tint)
                    .widgetAccentable()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(item))
    }

    private func corner(_ item: SharedSnapshot.Entry) -> some View {
        Image(systemName: entry.isPlaying ? "waveform" : "book.closed.fill")
            .font(.title3)
            .widgetAccentable()
            .widgetLabel {
                Gauge(value: item.progress) {
                    Text(item.title)
                } currentValueLabel: {
                    Text(HearthFormat.percent(item.progress))
                }
                .tint(entry.tint)
            }
            .accessibilityLabel(accessibilityLabel(item))
    }

    private func inline(_ item: SharedSnapshot.Entry) -> some View {
        let remaining = item.remaining.map { HearthFormat.remaining($0) } ?? ""
        return Label {
            Text(remaining.isEmpty ? item.title : "\(item.title) · \(remaining)")
        } icon: {
            Image(systemName: entry.isPlaying ? "waveform" : "play.fill")
        }
    }

    private var empty: some View {
        Group {
            switch family {
            case .accessoryInline:
                Label("Hearth", systemImage: "flame.fill")
            case .accessoryRectangular:
                VStack(alignment: .leading) {
                    Label("Hearth", systemImage: "flame.fill")
                        .font(.headline)
                        .widgetAccentable()
                    Text("Nothing to resume")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            default:
                Image(systemName: "flame.fill")
                    .font(.title2)
                    .widgetAccentable()
            }
        }
        .accessibilityLabel("Hearth")
    }

    // MARK: Helpers

    private var statusTitle: LocalizedStringKey {
        if entry.isPlaying {
            return "Playing"
        }
        return entry.isNowPlaying ? "Paused" : "Resume"
    }

    @ViewBuilder
    private func coverOrSymbol(size: CGFloat) -> some View {
        if let cover = entry.cover {
            Image(uiImage: cover)
                .resizable()
                .widgetAccentedRenderingMode(.fullColor)
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(family == .accessoryCircular ? AnyShape(Circle()) : AnyShape(Rectangle()))
        } else {
            Image(systemName: entry.isPlaying ? "waveform" : "headphones")
                .font(.system(size: size * 0.45, weight: .semibold))
                .frame(width: size, height: size)
                .widgetAccentable()
        }
    }

    private func accessibilityLabel(_ item: SharedSnapshot.Entry) -> String {
        let state = entry.isPlaying ? String(localized: "Playing") : (entry.isNowPlaying ? String(localized: "Paused") : String(localized: "Resume"))
        return "\(state): \(item.title), \(HearthFormat.percent(item.progress))"
    }
}

#Preview("Circular", as: .accessoryCircular) {
    NowPlayingComplication()
} timeline: {
    SnapshotEntry.preview
}

#Preview("Rectangular", as: .accessoryRectangular) {
    NowPlayingComplication()
} timeline: {
    SnapshotEntry.preview
}
