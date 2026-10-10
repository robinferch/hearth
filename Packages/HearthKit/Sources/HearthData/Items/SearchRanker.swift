import Foundation
import HearthModel

/// Similarity ranking for search results (local + server, all connections).
///
/// Score components:
/// - match class: exact (3) > prefix (2.5) > word prefix (2) > substring (1.5) > none (0)
/// - fuzzy similarity (normalized Levenshtein against the whole name and against word windows), 0…1
/// - token coverage (share of query words found), 0…0.5
/// Secondary fields (authors, narrators, podcast name) count at half weight.
enum SearchRanker {
    static func normalize(_ string: String) -> String {
        let folded = string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var result = ""
        result.reserveCapacity(folded.count)
        var lastWasSpace = true
        for character in folded {
            if character.isLetter || character.isNumber {
                result.append(character)
                lastWasSpace = false
            } else if !lastWasSpace {
                result.append(" ")
                lastWasSpace = true
            }
        }
        if result.hasSuffix(" ") {
            result.removeLast()
        }
        return result
    }

    static func tokens(_ string: String) -> [String] {
        normalize(string).split(separator: " ").map(String.init)
    }

    static func levenshtein(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0...rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)
        for (i, left) in lhs.enumerated() {
            current[0] = i + 1
            for (j, right) in rhs.enumerated() {
                let cost = left == right ? 0 : 1
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + cost)
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }

    /// 1 = identical, 0 = nothing in common.
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let lhs = Array(lhs)
        let rhs = Array(rhs)
        let length = max(lhs.count, rhs.count)
        guard length > 0 else { return 1 }
        return 1 - Double(levenshtein(lhs, rhs)) / Double(length)
    }

    /// Score of one normalized candidate against a normalized query.
    static func score(normalizedQuery query: String, normalizedCandidate candidate: String) -> Double {
        guard !query.isEmpty, !candidate.isEmpty else { return 0 }
        let candidateWords = candidate.split(separator: " ").map(String.init)
        let queryWords = query.split(separator: " ").map(String.init)

        let matchClass: Double
        if candidate == query {
            matchClass = 3
        } else if candidate.hasPrefix(query) {
            matchClass = 2.5
        } else if candidate.contains(" " + query) {
            matchClass = 2
        } else if candidate.contains(query) {
            matchClass = 1.5
        } else {
            matchClass = 0
        }

        var fuzzy = similarity(query, candidate)
        let window = max(1, queryWords.count)
        if candidateWords.count > window {
            for start in 0...(candidateWords.count - window) {
                let slice = candidateWords[start..<(start + window)].joined(separator: " ")
                fuzzy = max(fuzzy, similarity(query, slice) * 0.95)
            }
        }

        let covered = queryWords.filter { word in candidateWords.contains { $0.hasPrefix(word) } }.count
        let coverage = queryWords.isEmpty ? 0 : Double(covered) / Double(queryWords.count)

        return matchClass + fuzzy + 0.5 * coverage
    }

    static func score(query: String, name: String, secondary: [String] = []) -> Double {
        let query = normalize(query)
        let primary = score(normalizedQuery: query, normalizedCandidate: normalize(name))
        let other = secondary.map { score(normalizedQuery: query, normalizedCandidate: normalize($0)) }.max() ?? 0
        return max(primary, other * 0.5)
    }

    /// Sorts by descending score (stable), dropping duplicate ids.
    static func rank<T>(_ items: [T], query: String, id: (T) -> ItemIdentifier, name: (T) -> String, secondary: (T) -> [String] = { _ in [] }) -> [T] {
        var seen = Set<ItemIdentifier>()
        let unique = items.filter { seen.insert(id($0)).inserted }
        return unique.enumerated()
            .map { (offset: $0.offset, item: $0.element, score: score(query: query, name: name($0.element), secondary: secondary($0.element))) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
            .map(\.item)
    }

    static func rank(_ results: SearchResults, query: String) -> SearchResults {
        SearchResults(
            audiobooks: rank(results.audiobooks, query: query, id: \.id, name: \.name, secondary: { $0.authors + $0.narrators + $0.series.map(\.name) }),
            podcasts: rank(results.podcasts, query: query, id: \.id, name: \.name, secondary: \.authors),
            episodes: rank(results.episodes, query: query, id: \.id, name: \.name, secondary: { [$0.podcastName] }),
            authors: rank(results.authors, query: query, id: \.id, name: \.name),
            narrators: rank(results.narrators, query: query, id: \.id, name: \.name),
            series: rank(results.series, query: query, id: \.id, name: \.name, secondary: \.authors)
        )
    }
}
