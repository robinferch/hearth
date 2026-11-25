import Foundation
import HearthModel
import Testing

@Suite struct TranscriptTests {
    static let id = ItemIdentifier(kind: .episode, connectionID: "c", libraryID: "l", primaryID: "e", groupingID: "p")

    static func segment(_ start: TimeInterval, _ end: TimeInterval, _ text: String) -> TranscriptSegment {
        let words = text.split(separator: " ").enumerated().map { index, word in
            let step = (end - start) / Double(max(1, text.split(separator: " ").count))
            return TranscriptWord(text: String(word), start: start + Double(index) * step, end: start + Double(index + 1) * step)
        }
        return TranscriptSegment(start: start, end: end, text: text, words: words)
    }

    let transcript = Transcript(itemID: id, localeIdentifier: "de-DE", duration: 60, segments: [
        segment(0, 5, "Willkommen zur Folge"),
        segment(6, 12, "Heute geht es um Kaffee"),
        segment(30, 40, "Unser Sponsor ist Rösterei Müller"),
    ])

    @Test func findsTheSegmentPlayingAtATime() {
        #expect(transcript.segmentIndex(at: -1) == nil)
        #expect(transcript.segmentIndex(at: 0) == 0)
        #expect(transcript.segmentIndex(at: 5.5) == 0)
        #expect(transcript.segmentIndex(at: 7) == 1)
        // A long pause after a segment: nothing is highlighted.
        #expect(transcript.segmentIndex(at: 20) == nil)
        #expect(transcript.segmentIndex(at: 35) == 2)
    }

    @Test func findsTheWordPlayingAtATime() {
        #expect(transcript.wordIndex(at: 6.1, inSegment: 1) == 0)
        #expect(transcript.wordIndex(at: 11.9, inSegment: 1) == 4)
        #expect(transcript.wordIndex(at: 3, inSegment: 7) == nil)
    }

    @Test func searchIgnoresCaseAndDiacritics() {
        #expect(transcript.search("rosterei") == [2])
        #expect(transcript.search("FOLGE") == [0])
        #expect(transcript.search("  ").isEmpty)
    }

    @Test func roundTripsThroughCompactJSON() throws {
        let data = try JSONEncoder().encode(transcript)
        #expect(String(decoding: data, as: UTF8.self).contains(#""w":"#))
        #expect(try JSONDecoder().decode(Transcript.self, from: data) == transcript)
        #expect(transcript.plainText.hasPrefix("Willkommen zur Folge\n\nHeute"))
    }

    @Test func groupsSentencesIntoParagraphs() {
        let sentences = Transcript(itemID: Self.id, localeIdentifier: "en", duration: 200, segments: [
            Self.segment(0, 10, "a b c."), Self.segment(10.5, 20, "d e f."), Self.segment(20.2, 35, "g h i."),
            Self.segment(35.1, 50, "j k l."),
            Self.segment(60, 70, "m n o."), Self.segment(70.1, 80, "p q r."), Self.segment(80.1, 90, "s t u."),
        ])
        // Long → split before 35.1; pause before 60; ad starting at 70.1.
        #expect(sentences.paragraphs(maximumDuration: 40, breaks: [70.1]) == [0 ..< 3, 3 ..< 4, 4 ..< 5, 5 ..< 7])
        #expect(Transcript(itemID: Self.id, localeIdentifier: "en", duration: 0, segments: []).paragraphs().isEmpty)
    }

    @Test func normalizesAdSegments() {
        let merged = AdAnalysis.normalized([
            AdSegment(id: 9, start: 100, end: 130, confidence: 0.5),
            AdSegment(id: 3, start: 10, end: 40, advertiser: nil, confidence: 0.9),
            AdSegment(id: 4, start: 42, end: 60, advertiser: "Acme", confidence: 0.6),
            AdSegment(id: 5, start: 70, end: 70, confidence: 1),
        ])
        #expect(merged.map(\.start) == [10, 100])
        #expect(merged[0].end == 60)
        #expect(merged[0].advertiser == "Acme")
        #expect(merged[0].confidence == 0.9)
        #expect(merged.map(\.id) == [0, 1])
    }
}
