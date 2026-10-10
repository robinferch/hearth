import Foundation
import HearthModel

/// Parses chapter timestamps from episode show notes: lines starting with `(H:)MM:SS Title`,
/// optionally wrapped in parentheses/brackets.
///
/// HearthAPI will expose a public `ChapterParser`; until then the player uses this internal one.
enum DescriptionChapterParser {
    static func chapters(from description: String?, duration: TimeInterval) -> [Chapter] {
        guard let description, !description.isEmpty else { return [] }

        var starts: [(start: TimeInterval, title: String)] = []
        for rawLine in plainText(from: description).components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let match = line.wholeMatch(of: /^[\(\[]?(?:(\d{1,2}):)?(\d{1,2}):(\d{2})[\)\]]?[\s\-–—:|.]*(.*)$/) else {
                continue
            }
            let hours = match.output.1.flatMap { Int($0) } ?? 0
            guard let minutes = Int(match.output.2), let seconds = Int(match.output.3), seconds < 60 else { continue }
            if match.output.1 != nil, minutes >= 60 {
                continue
            }
            let start = TimeInterval(hours * 3600 + minutes * 60 + seconds)
            if duration > 0, start >= duration {
                continue
            }
            // Timestamps must be strictly increasing.
            if let last = starts.last, start <= last.start {
                continue
            }
            let title = match.output.4.trimmingCharacters(in: .whitespaces)
            starts.append((start, title))
        }

        guard starts.count >= 2 else { return [] }

        return starts.enumerated().map { offset, entry in
            let end = offset + 1 < starts.count ? starts[offset + 1].start : max(duration, entry.start)
            let title = entry.title.isEmpty ? String(localized: "Chapter \(offset + 1)") : entry.title
            return Chapter(id: offset, start: entry.start, end: end, title: title)
        }
    }

    /// Converts simple HTML into plain text with line breaks.
    static func plainText(from html: String) -> String {
        var text = html
        text = text.replacing(/(?i)<br\s*\/?>/, with: "\n")
        text = text.replacing(/(?i)<\/(p|div|li|h[1-6])>/, with: "\n")
        text = text.replacing(/<[^>]+>/, with: "")
        let entities = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text
    }
}
