import Foundation
import HearthData
import HearthModel

/// Localized formatting helpers shared by all Hearth UIs.
public enum HearthFormat {
    /// Separator used in compact info lines.
    public static let separator = " • "

    /// `5h 12m`, `42m 10s`.
    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        if seconds < 60 {
            return Duration.seconds(seconds).formatted(.units(allowed: [.seconds], width: .narrow))
        }
        return seconds.durationFormatted
    }

    /// Duration in wall-clock time at the given playback rate.
    public static func duration(_ seconds: TimeInterval, rate: Double) -> String {
        duration(seconds / max(rate, 0.1))
    }

    /// `3h 12m left` (divided by the playback rate).
    public static func remaining(_ seconds: TimeInterval, rate: Double = 1) -> String {
        let value = duration(seconds, rate: rate)
        guard !value.isEmpty else { return "" }
        return String(localized: "\(value) left", bundle: .module, comment: "Remaining listening time, e.g. '3h 12m left'")
    }

    /// `1:02:03`.
    public static func clock(_ seconds: TimeInterval) -> String {
        seconds.clockFormatted
    }

    /// `42 %`.
    public static func percent(_ fraction: Double) -> String {
        min(max(fraction, 0), 1).formatted(.percent.precision(.fractionLength(0)))
    }

    /// `12 min`.
    public static func minutes(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.down))
        return Duration.seconds(Double(minutes) * 60).formatted(.units(allowed: [.minutes], width: .abbreviated))
    }

    /// Hours and minutes for long totals (`123h 5m`).
    public static func totalTime(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return Duration.seconds(0).formatted(.units(allowed: [.minutes], width: .abbreviated)) }
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
    }

    /// `yesterday`, `3 days ago`.
    public static func relative(_ date: Date, to reference: Date = .now) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }

    /// Short date (`Oct 10, 2026`), or relative within the last week.
    public static func releaseDate(_ date: Date, now: Date = .now) -> String {
        let interval = now.timeIntervalSince(date)
        if interval >= 0, interval < 6 * 24 * 3600 {
            return relative(date)
        }
        let sameYear = Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
        if sameYear {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// Four-digit year from an ABS `publishedYear` / `publishedDate` string.
    public static func year(from released: String?) -> String? {
        guard let released, released.count >= 4 else { return nil }
        let prefix = released.prefix(4)
        guard prefix.allSatisfy(\.isNumber) else { return nil }
        return String(prefix)
    }

    /// `1.3×`.
    public static func rate(_ rate: Double) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    /// `1.2 GB`.
    public static func bytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Joins non-empty parts with ` • `.
    public static func joined(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: separator)
    }

    /// `"Finished yesterday"`.
    public static func finished(_ date: Date?) -> String {
        guard let date else { return loc("Finished") }
        let relative = relative(date)
        return String(localized: "Finished \(relative)", bundle: .module, comment: "e.g. 'Finished yesterday'")
    }

    /// `N books`.
    public static func bookCount(_ count: Int) -> String {
        String(localized: "\(count) books", bundle: .module, comment: "Number of audiobooks")
    }

    /// `N episodes`.
    public static func episodeCount(_ count: Int) -> String {
        String(localized: "\(count) episodes", bundle: .module, comment: "Number of podcast episodes")
    }

    /// `N unplayed`.
    public static func unplayedCount(_ count: Int) -> String {
        String(localized: "\(count) unplayed", bundle: .module, comment: "Number of unplayed podcast episodes")
    }

    /// `N items`.
    public static func itemCount(_ count: Int) -> String {
        String(localized: "\(count) items", bundle: .module, comment: "Number of items in a list")
    }

    /// `#3`.
    public static func sequence(_ sequence: String?) -> String? {
        guard let sequence, !sequence.isEmpty else { return nil }
        return "#\(sequence)"
    }

    /// Strips HTML tags and decodes common entities for single-line previews.
    public static func plainText(fromHTML html: String?) -> String? {
        guard var text = html, !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
        for (entity, value) in entities {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Item kinds

public extension ItemIdentifier.Kind {
    /// SF Symbol used for placeholders and labels.
    var systemImage: String {
        switch self {
        case .audiobook: "book.closed"
        case .author: "person.fill"
        case .narrator: "waveform"
        case .series: "books.vertical"
        case .podcast: "antenna.radiowaves.left.and.right"
        case .episode: "waveform.circle"
        case .collection: "rectangle.stack"
        case .playlist: "music.note.list"
        }
    }

    /// Localized type name ("Audiobook").
    var localizedName: String {
        switch self {
        case .audiobook: loc("Audiobook")
        case .author: loc("Author")
        case .narrator: loc("Narrator")
        case .series: loc("Series")
        case .podcast: loc("Podcast")
        case .episode: loc("Episode")
        case .collection: loc("Collection")
        case .playlist: loc("Playlist")
        }
    }
}

public extension AnyItem {
    /// Secondary line for compact rows.
    var subtitle: String? {
        switch self {
        case .audiobook(let book): book.authorLine
        case .podcast(let podcast): podcast.authorLine
        case .episode(let episode): episode.podcastName
        case .person(let person): HearthFormat.bookCount(person.bookCount)
        case .series(let series): HearthFormat.bookCount(series.bookCount)
        case .collection(let collection): HearthFormat.itemCount(collection.items.count)
        }
    }
}

public extension AutoDownloadRule {
    /// Localized description used by settings and configure sheets.
    var localizedName: String {
        switch self {
        case .disabled: loc("Disabled")
        case .all: loc("All")
        case .nextUnfinished(let count): String(localized: "Next \(count) unfinished", bundle: .module)
        case .releasedWithin(let hours):
            switch hours {
            case 24: loc("Released in the last 24 hours")
            case 168: loc("Released in the last week")
            case 336: loc("Released in the last 2 weeks")
            case 720, 744: loc("Released in the last month")
            default: String(localized: "Released in the last \(hours) hours", bundle: .module)
            }
        }
    }

    /// Options offered for a grouping kind.
    static func options(forPodcast isPodcast: Bool) -> [AutoDownloadRule] {
        var options: [AutoDownloadRule] = [.disabled]
        options += [1, 2, 3, 4, 5, 10].map { .nextUnfinished(count: $0) }
        if isPodcast {
            options += [24, 168, 336, 720].map { .releasedWithin(hours: $0) }
        }
        options.append(.all)
        return options
    }
}
