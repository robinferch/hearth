import Foundation

/// Converts the HTML descriptions delivered by audiobookshelf into an `AttributedString`.
///
/// A small, dependency-free parser (no WebKit / `NSAttributedString(html:)`, so it is fast, works off the main
/// actor and on watchOS). Supports paragraphs, line breaks, lists, headings, bold / italic and links. Optionally
/// turns timestamps such as `12:34` or `1:02:03` into `hearth://seek/<seconds>` links.
public enum HTMLText {
    /// Scheme + host of internal seek links (`hearth://seek/754`).
    public static let seekURLPrefix = "hearth://seek/"

    /// Seconds encoded in a `hearth://seek/<seconds>` URL.
    public static func seekTime(from url: URL) -> TimeInterval? {
        guard url.scheme?.lowercased() == "hearth", url.host()?.lowercased() == "seek" else { return nil }
        let value = url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return TimeInterval(value)
    }

    public static func seekURL(for seconds: TimeInterval) -> URL? {
        URL(string: seekURLPrefix + String(Int(seconds.rounded(.down))))
    }

    /// Parses `html` (or plain text) into an attributed string.
    /// - Parameter linkTimestamps: Turns `(H:)MM:SS` timestamps into seek links (episode descriptions).
    public static func attributedString(from html: String, linkTimestamps: Bool = false) -> AttributedString {
        var parser = Parser()
        let looksLikeHTML = html.range(of: "<[a-zA-Z/][^>]*>", options: .regularExpression) != nil
        if looksLikeHTML {
            parser.parse(html)
        } else {
            parser.appendPlain(html)
        }
        var result = parser.finish()
        if linkTimestamps {
            linkifyTimestamps(in: &result)
        }
        linkifyBareURLs(in: &result)
        return result
    }

    // MARK: Timestamps

    /// Regex for `1:02:03` / `12:34` not embedded in longer numbers.
    private static let timestampPattern = "(?<![\\d:])(?:(\\d{1,2}):)?(\\d{1,2}):(\\d{2})(?![\\d:])"

    /// All timestamps (in seconds) found in a text, in order of appearance.
    public static func timestamps(in text: String) -> [TimeInterval] {
        guard let regex = try? NSRegularExpression(pattern: timestampPattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { seconds(from: $0, in: ns) }
    }

    private static func seconds(from match: NSTextCheckingResult, in text: NSString) -> TimeInterval? {
        func value(_ index: Int) -> Int? {
            let range = match.range(at: index)
            guard range.location != NSNotFound else { return nil }
            return Int(text.substring(with: range))
        }
        guard let minutes = value(2), let seconds = value(3), seconds < 60 else { return nil }
        let hours = value(1) ?? 0
        if hours > 0, minutes >= 60 { return nil }
        return TimeInterval(hours * 3600 + minutes * 60 + seconds)
    }

    private static func linkifyTimestamps(in string: inout AttributedString) {
        guard let regex = try? NSRegularExpression(pattern: timestampPattern) else { return }
        let plain = String(string.characters)
        let ns = plain as NSString
        let matches = regex.matches(in: plain, range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            guard let seconds = seconds(from: match, in: ns),
                  let stringRange = Range(match.range, in: plain),
                  let range = attributedRange(stringRange, in: string, plain: plain),
                  string[range].link == nil,
                  let url = seekURL(for: seconds)
            else { continue }
            string[range].link = url
        }
    }

    private static func linkifyBareURLs(in string: inout AttributedString) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        let plain = String(string.characters)
        let ns = plain as NSString
        for match in detector.matches(in: plain, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard let url = match.url, let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme),
                  let stringRange = Range(match.range, in: plain),
                  let range = attributedRange(stringRange, in: string, plain: plain),
                  string[range].link == nil
            else { continue }
            string[range].link = url
        }
    }

    private static func attributedRange(_ range: Range<String.Index>, in string: AttributedString, plain: String) -> Range<AttributedString.Index>? {
        let startOffset = plain.distance(from: plain.startIndex, to: range.lowerBound)
        let length = plain.distance(from: range.lowerBound, to: range.upperBound)
        let start = string.characters.index(string.startIndex, offsetBy: startOffset)
        let end = string.characters.index(start, offsetBy: length)
        return start..<end
    }

    // MARK: Entities

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "&", let semicolon = text[index...].prefix(12).firstIndex(of: ";") else {
                result.append(character)
                index = text.index(after: index)
                continue
            }
            let name = String(text[text.index(after: index)..<semicolon])
            if let decoded = decodeEntity(name) {
                result.append(decoded)
                index = text.index(after: semicolon)
            } else {
                result.append(character)
                index = text.index(after: index)
            }
        }
        return result
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "laquo": "«", "raquo": "»", "bull": "•", "middot": "·", "copy": "©", "reg": "®", "trade": "™",
        "auml": "ä", "ouml": "ö", "uuml": "ü", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß",
        "eacute": "é", "egrave": "è", "aacute": "á", "agrave": "à", "ccedil": "ç", "euro": "€", "shy": "",
    ]

    private static func decodeEntity(_ name: String) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value: UInt32?
            if digits.first == "x" || digits.first == "X" {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits)
            }
            return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return namedEntities[name]
    }

    // MARK: Parser

    private struct Parser {
        var output = AttributedString()
        var bold = 0
        var italic = 0
        var links: [URL?] = []
        var listStack: [(ordered: Bool, counter: Int)] = []
        /// Pending whitespace between words.
        var pendingSpace = false
        /// Number of trailing newlines already emitted.
        var trailingNewlines = 2
        var skipDepth = 0

        mutating func parse(_ html: String) {
            var index = html.startIndex
            var text = ""
            while index < html.endIndex {
                let character = html[index]
                if character == "<", let close = html[index...].firstIndex(of: ">") {
                    if !text.isEmpty {
                        appendText(text)
                        text = ""
                    }
                    let tag = String(html[html.index(after: index)..<close])
                    handleTag(tag)
                    index = html.index(after: close)
                } else {
                    text.append(character)
                    index = html.index(after: index)
                }
            }
            if !text.isEmpty {
                appendText(text)
            }
        }

        mutating func appendPlain(_ text: String) {
            let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            for (offset, line) in lines.enumerated() {
                if offset > 0 {
                    newline(1)
                }
                appendText(line, collapse: false)
            }
        }

        mutating func finish() -> AttributedString {
            // Trim trailing newlines.
            while let last = output.characters.last, last.isNewline || last == " " {
                output.characters.removeLast()
            }
            return output
        }

        private mutating func handleTag(_ raw: String) {
            if raw.hasPrefix("!") { return } // comments / doctype
            let closing = raw.hasPrefix("/")
            let body = closing ? String(raw.dropFirst()) : raw
            let name = body.prefix { !$0.isWhitespace && $0 != "/" }.lowercased()

            if ["script", "style", "head"].contains(name) {
                skipDepth += closing ? -1 : 1
                skipDepth = max(0, skipDepth)
                return
            }

            switch name {
            case "br":
                newline(1, force: true)
            case "p", "div", "section", "article", "blockquote", "pre", "table", "tr":
                newline(2)
            case "h1", "h2", "h3", "h4", "h5", "h6":
                newline(2)
                bold += closing ? -1 : 1
            case "ul", "ol":
                if closing {
                    _ = listStack.popLast()
                } else {
                    listStack.append((ordered: name == "ol", counter: 0))
                }
                newline(listStack.isEmpty ? 2 : 1)
            case "li":
                if closing {
                    newline(1)
                } else {
                    newline(1)
                    let depth = max(0, listStack.count - 1)
                    var marker = String(repeating: "    ", count: depth)
                    if var list = listStack.popLast() {
                        list.counter += 1
                        marker += list.ordered ? "\(list.counter). " : "• "
                        listStack.append(list)
                    } else {
                        marker += "• "
                    }
                    emit(marker)
                }
            case "b", "strong":
                bold = max(0, bold + (closing ? -1 : 1))
            case "i", "em", "cite":
                italic = max(0, italic + (closing ? -1 : 1))
            case "a":
                if closing {
                    _ = links.popLast()
                } else {
                    links.append(Self.attribute("href", in: body).flatMap { URL(string: HTMLText.decodeEntities($0).trimmingCharacters(in: .whitespaces)) })
                }
            case "hr":
                newline(2)
            default:
                break
            }
        }

        private static func attribute(_ name: String, in tag: String) -> String? {
            let pattern = "\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
            let ns = tag as NSString
            guard let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)) else { return nil }
            for group in 2...4 {
                let range = match.range(at: group)
                if range.location != NSNotFound {
                    return ns.substring(with: range)
                }
            }
            return nil
        }

        private mutating func appendText(_ raw: String, collapse: Bool = true) {
            guard skipDepth == 0 else { return }
            let decoded = HTMLText.decodeEntities(raw)
            guard collapse else {
                emit(decoded)
                return
            }
            var word = ""
            for character in decoded {
                if character.isWhitespace, character != "\u{00A0}" {
                    if !word.isEmpty {
                        emit(word)
                        word = ""
                    }
                    pendingSpace = true
                } else {
                    word.append(character)
                }
            }
            if !word.isEmpty {
                emit(word)
            }
        }

        private mutating func emit(_ text: String) {
            guard !text.isEmpty else { return }
            if pendingSpace, trailingNewlines == 0, !output.characters.isEmpty {
                output.append(AttributedString(" "))
            }
            pendingSpace = false
            var piece = AttributedString(text)
            var intent: InlinePresentationIntent = []
            if bold > 0 { intent.insert(.stronglyEmphasized) }
            if italic > 0 { intent.insert(.emphasized) }
            if !intent.isEmpty {
                piece.inlinePresentationIntent = intent
            }
            if let link = links.last(where: { $0 != nil }) ?? nil {
                piece.link = link
            }
            output.append(piece)
            trailingNewlines = text.hasSuffix("\n") ? 1 : 0
        }

        private mutating func newline(_ count: Int, force: Bool = false) {
            pendingSpace = false
            guard !output.characters.isEmpty else { return }
            let needed = force ? 1 : max(0, count - trailingNewlines)
            guard needed > 0 else { return }
            output.append(AttributedString(String(repeating: "\n", count: needed)))
            trailingNewlines += needed
        }
    }
}
