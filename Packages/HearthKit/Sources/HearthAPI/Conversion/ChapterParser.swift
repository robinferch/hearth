import Foundation
import HearthModel

/// Extracts chapters from podcast episode show notes.
///
/// Recognises lines that start with a timestamp – `MM:SS Title`, `HH:MM:SS Title`, optionally wrapped in
/// brackets and followed by a separator (`(01:02:03) – Title`, `[12:34] Title`). HTML descriptions are
/// converted to plain text lines first. Returns an empty array unless at least two chapters were found.
public enum ChapterParser {
    public static func parse(description: String, duration: TimeInterval) -> [Chapter] {
        var markers: [(start: TimeInterval, title: String)] = []
        for line in plainTextLines(description) {
            guard let marker = parseLine(line) else { continue }
            if duration > 0, marker.start >= duration { continue }
            markers.append(marker)
        }

        markers.sort { $0.start < $1.start }
        var unique: [(start: TimeInterval, title: String)] = []
        for marker in markers where unique.last?.start != marker.start {
            unique.append(marker)
        }
        guard unique.count >= 2 else {
            return []
        }

        return unique.enumerated().map { index, marker in
            let end = index + 1 < unique.count ? unique[index + 1].start : max(duration, marker.start)
            return Chapter(id: index, start: marker.start, end: end, title: marker.title)
        }
    }

    /// Parses `"(1:02:03) - Title"` into `(3723, "Title")`.
    static func parseLine(_ line: String) -> (start: TimeInterval, title: String)? {
        var rest = Substring(line).drop { $0.isWhitespace }
        let opening = rest.first
        let closing: Character?
        switch opening {
        case "(": closing = ")"
        case "[": closing = "]"
        default: closing = nil
        }
        if closing != nil {
            rest = rest.dropFirst()
        }

        var stamp = rest.prefix { $0.isASCII && ($0.isNumber || $0 == ":") }
        while stamp.hasSuffix(":") {
            stamp = stamp.dropLast()
        }
        guard let start = seconds(from: stamp) else {
            return nil
        }
        rest = rest.dropFirst(stamp.count)

        if let closing {
            guard rest.first == closing else { return nil }
            rest = rest.dropFirst()
        }

        // A timestamp must be followed by a separator or whitespace, not glued to a word ("12:34pm").
        guard rest.isEmpty || rest.first!.isWhitespace || "-–—|:.".contains(rest.first!) else {
            return nil
        }
        rest = rest.drop { $0.isWhitespace }
        if let first = rest.first, "-–—|:.".contains(first) {
            rest = rest.dropFirst().drop { $0.isWhitespace }
        }

        var title = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            title = String(stamp)
        }
        return (start, title)
    }

    /// `"MM:SS"` / `"H:MM:SS"` → seconds. Rejects malformed values.
    static func seconds(from stamp: Substring) -> TimeInterval? {
        let parts = stamp.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var values: [Int] = []
        for (index, part) in parts.enumerated() {
            guard !part.isEmpty, part.count <= (index == 0 ? 3 : 2), let value = Int(part) else { return nil }
            if index > 0, part.count != 2 || value >= 60 { return nil }
            values.append(value)
        }
        if values.count == 3 {
            return TimeInterval(values[0] * 3600 + values[1] * 60 + values[2])
        }
        return TimeInterval(values[0] * 60 + values[1])
    }

    /// Converts HTML (or plain text) into trimmed, non-empty lines.
    static func plainTextLines(_ text: String) -> [String] {
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if character == "<", let close = text[index...].firstIndex(of: ">") {
                let tag = text[text.index(after: index) ..< close].lowercased().trimmingCharacters(in: .whitespaces)
                let name = tag.drop { $0 == "/" }.prefix { $0.isLetter || $0.isNumber }
                if ["br", "p", "div", "li", "ul", "ol", "tr", "h1", "h2", "h3", "h4", "h5", "h6"].contains(String(name)) {
                    result.append("\n")
                }
                index = text.index(after: close)
            } else {
                result.append(character)
                index = text.index(after: index)
            }
        }

        return decodeEntities(result)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "–", "mdash": "—", "hellip": "…", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "&", let semicolon = text[index...].prefix(10).firstIndex(of: ";") {
                let entity = text[text.index(after: index) ..< semicolon]
                if let decoded = decodeEntity(entity) {
                    result.append(decoded)
                    index = text.index(after: semicolon)
                    continue
                }
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }

    private static func decodeEntity(_ entity: Substring) -> String? {
        if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
            return UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        if entity.hasPrefix("#") {
            return UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return namedEntities[entity.lowercased()]
    }
}
