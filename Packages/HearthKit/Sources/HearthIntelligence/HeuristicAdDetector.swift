import Foundation
import HearthModel

/// Finds sponsor reads with keyword cues (German and English), at sentence precision. Used without Apple Intelligence
/// and for windows the language model couldn't handle. Errs on the side of not skipping content.
public struct HeuristicAdDetector: Sendable {
    /// Gap between hits that still belongs to the same ad block.
    public var joinGap: TimeInterval = 40
    public var minimumDuration: TimeInterval = 6
    public var maximumDuration: TimeInterval = 240

    public init() {}

    private static let strongCues = [
        "sponsored by", "brought to you by", "today's sponsor", "todays sponsor", "this episode is sponsored",
        "this podcast is supported by", "this episode is supported by", "our sponsor", "promo code", "discount code",
        "coupon code", "use code", "use the code", "with the code", "presented by", "paid partnership",
        "werbung", "anzeige", "werbepartner", "unser sponsor", "unserem sponsor", "unseres sponsors", "sponsor dieser folge",
        "sponsor der heutigen folge", "rabattcode", "gutscheincode", "gutschein code", "mit dem code", "mit dem rabattcode",
        "präsentiert von", "prasentiert von", "unterstützt von", "unterstutzt von", "in kooperation mit", "kooperationspartner",
    ]

    private static let mediumCues = [
        "% off", "percent off", "first month free", "free trial", "sign up at", "go to", "head to", "visit",
        "link in the show notes", "link in the description", "check out", "limited time",
        "prozent rabatt", "% rabatt", "rabatt", "ersten monat", "kostenlos testen", "gratis testen", "probemonat",
        "link in den shownotes", "link in der beschreibung", "jetzt bestellen", "jetzt testen", "geht auf", "besucht",
        "schaut vorbei", "nur für kurze zeit", "nur fur kurze zeit",
    ]

    private static let endCues = [
        "back to the show", "back to the episode", "and now back", "zurück zur folge", "zuruck zur folge",
        "zurück zum thema", "zuruck zum thema", "und jetzt weiter", "weiter geht's", "weiter gehts",
    ]

    /// `example.com`, `example punkt de`, `example dot com/podcast`.
    nonisolated(unsafe) private static let urlPattern = /\b[a-z0-9-]{2,}\s?(\.|punkt|dot)\s?(com|de|at|ch|io|net|org|co|fm|shop)\b/

    public func detect(in segments: [TranscriptSegment]) -> [AdSegment] {
        let scores = segments.map(Self.score)
        var clusters: [ClosedRange<Int>] = []
        var current: ClosedRange<Int>?
        for index in segments.indices where scores[index] >= 3 {
            if let range = current, segments[index].start - segments[range.upperBound].end <= joinGap {
                current = range.lowerBound ... index
            } else {
                if let range = current { clusters.append(range) }
                current = index ... index
            }
        }
        if let range = current { clusters.append(range) }

        var result: [AdSegment] = []
        for cluster in clusters {
            var lower = cluster.lowerBound
            var upper = cluster.upperBound
            // Neighbouring sentences with weaker cues belong to the read.
            while lower > 0, scores[lower - 1] >= 1, segments[cluster.lowerBound].start - segments[lower - 1].start <= 30 {
                lower -= 1
            }
            while upper < segments.count - 1, scores[upper + 1] >= 1, !Self.isEnd(segments[upper]), segments[upper + 1].end - segments[cluster.upperBound].end <= 30 {
                upper += 1
            }
            // Blocks only cover sentences with ad cues: skipping a few seconds too little is better than cutting
            // into the episode.
            let start = segments[lower].start
            let end = segments[upper].end
            let total = scores[lower ... upper].reduce(0, +)
            guard total >= 5, end - start >= minimumDuration, end - start <= maximumDuration else { continue }
            result.append(AdSegment(id: result.count, start: start, end: end, confidence: min(0.8, Double(total) / 12)))
        }
        return AdAnalysis.normalized(result)
    }

    static func score(_ segment: TranscriptSegment) -> Int {
        let text = segment.text.folding(options: [.caseInsensitive], locale: nil).lowercased()
        var score = 0
        for cue in strongCues where text.contains(cue) {
            score += 3
        }
        for cue in mediumCues where text.contains(cue) {
            score += 1
        }
        if text.contains(urlPattern) {
            score += 2
        }
        return score
    }

    static func isEnd(_ segment: TranscriptSegment) -> Bool {
        let text = segment.text.lowercased()
        return endCues.contains { text.contains($0) }
    }
}
