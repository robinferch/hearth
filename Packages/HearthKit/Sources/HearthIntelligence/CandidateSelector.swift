import Foundation
import HearthModel

/// Picks the parts of a transcript that may contain ads, so a slow on-device model only reads those (~12 % of a typical
/// episode instead of all of it).
///
/// Recall matters more than precision here – the model decides. A sentence is a candidate when it has a sponsor cue
/// (`HeuristicAdDetector`) or at least two broader commerce cues ("jetzt", "bezahl", "Angebot", "%", …). Each candidate
/// brings `context` sentences on both sides, so the model sees where a read starts and ends.
public struct CandidateSelector: Sendable {
    public var context = 3
    public var minimumCues = 2

    public init() {}

    private static let cues = [
        "werbung", "anzeige", "sponsor", "partner", "präsentiert", "prasentiert", "unterstützt", "unterstutzt", "kooperation",
        "rabatt", "code", "gutschein", "prozent", "%", "euro", "angebot", "deal", "gratis", "kostenlos", "testen", "probe",
        "abo", "bestell", "shop", "kauf", "bezahl", "zahl", "app ", "download", "herunterlad", "link", "shownotes",
        "beschreibung", "jetzt", "sichern", "exklusiv", "bedingungen", "erhältlich", "erhaltlich", "www", "punkt de",
        "dot com", ".de", ".com", "sponsored", "brought to you", "promo", "discount", "offer", "free", "sign up", "visit",
    ]

    /// Sorted, non-overlapping ranges of segment indices to read.
    public func regions(in segments: [TranscriptSegment]) -> [Range<Int>] {
        var regions: [Range<Int>] = []
        for (index, segment) in segments.enumerated() where Self.isCandidate(segment, minimumCues: minimumCues) {
            let range = max(0, index - context) ..< min(segments.count, index + context + 1)
            if let last = regions.last, range.lowerBound <= last.upperBound {
                regions[regions.count - 1] = last.lowerBound ..< max(last.upperBound, range.upperBound)
            } else {
                regions.append(range)
            }
        }
        return regions
    }

    static func isCandidate(_ segment: TranscriptSegment, minimumCues: Int) -> Bool {
        if HeuristicAdDetector.score(segment) >= 1 {
            return true
        }
        let text = segment.text.lowercased()
        var count = 0
        for cue in cues where text.contains(cue) {
            count += 1
            if count >= minimumCues { return true }
        }
        return false
    }
}
