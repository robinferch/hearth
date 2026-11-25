import CoreMedia
import Foundation
import HearthModel
import Speech
import Testing
@testable import HearthIntelligence

private func segment(_ start: TimeInterval, _ end: TimeInterval, _ text: String) -> TranscriptSegment {
    TranscriptSegment(start: start, end: end, text: text)
}

@Suite struct HeuristicAdDetectorTests {
    @Test func findsAGermanSponsorRead() {
        let segments = [
            segment(0, 20, "Herzlich willkommen zu einer neuen Folge, heute sprechen wir über Kochen."),
            segment(20, 40, "Ich habe letzte Woche ein neues Rezept ausprobiert."),
            segment(40, 55, "Bevor es weitergeht, ein Wort zu unserem Sponsor dieser Folge."),
            segment(55, 75, "Hello Fresh liefert euch frische Zutaten direkt nach Hause."),
            segment(75, 95, "Mit dem Rabattcode KOCHEN bekommt ihr 50 Prozent Rabatt auf die erste Box, geht auf hellofresh punkt de."),
            segment(95, 110, "So, und jetzt zurück zur Folge."),
            segment(110, 140, "Also, wo waren wir? Beim Rezept für die Lasagne."),
        ]
        let ads = HeuristicAdDetector().detect(in: segments)
        #expect(ads.count == 1)
        #expect(ads.first?.start == 40)
        #expect((ads.first?.end ?? 0) >= 95)
        #expect((ads.first?.end ?? 0) <= 110)
    }

    @Test func findsAnEnglishHostRead() {
        let segments = [
            segment(0, 30, "So that's how the experiment went."),
            segment(30, 50, "This episode is brought to you by Squarespace."),
            segment(50, 70, "Go to squarespace dot com slash show and use code SHOW for ten percent off."),
            segment(70, 100, "Anyway, back to the show and the results."),
        ]
        let ads = HeuristicAdDetector().detect(in: segments)
        #expect(ads.map(\.start) == [30])
    }

    @Test func ignoresNormalConversation() {
        let segments = [
            segment(0, 30, "Ich war gestern im Supermarkt und habe Kaffee gekauft."),
            segment(30, 60, "Der war im Angebot, aber eigentlich schmeckt er nicht so gut."),
            segment(60, 90, "Habt ihr einen Tipp für guten Kaffee? Schreibt uns gerne."),
        ]
        #expect(HeuristicAdDetector().detect(in: segments).isEmpty)
    }
}

@Suite struct AdDetectorTests {
    @Test func splitsLongTranscriptsIntoOverlappingWindows() {
        let segments = (0 ..< 100).map { segment(Double($0) * 10, Double($0) * 10 + 9, String(repeating: "wort ", count: 20)) }
        let windows = AdDetector.windows(for: segments, characters: 1_000, overlap: 2)
        #expect(windows.first?.lowerBound == 0)
        #expect(windows.last?.upperBound == 100)
        for (previous, next) in zip(windows, windows.dropFirst()) {
            #expect(next.lowerBound == previous.upperBound - 2)
        }
        #expect(windows.allSatisfy { $0.count >= 3 })
    }

    @Test func mapsModelLinesToTimesAndDropsImplausibleBlocks() {
        let segments = (0 ..< 20).map { segment(Double($0) * 10, Double($0) * 10 + 10, "line \($0)") }
        let ads = AdDetector.adSegments(from: [(3, 5, "Acme"), (8, 8, nil), (12, 99, " "), (10, 2, nil)], window: 0 ..< 15, segments: segments)
        #expect(ads.map(\.start) == [30, 80, 120, 100])
        #expect(ads.map(\.end) == [60, 90, 150, 110])
        #expect(ads[0].advertiser == "Acme")
        #expect(ads[2].advertiser == nil)
        let tooLong = AdDetector.adSegments(from: [(0, 14, nil)], window: 0 ..< 15, segments: (0 ..< 15).map { segment(Double($0) * 60, Double($0) * 60 + 60, "x") })
        #expect(tooLong.isEmpty)
    }
}

@Suite struct TimeEstimatorTests {
    @Test func estimatesFromMeasuredSpeeds() {
        let estimator = TimeEstimator(transcriptionSpeed: 30, secondsPerAdWindow: 5)
        let estimate = estimator.estimate(duration: 3600, detectAds: true, downloadBytes: 50_000_000, needsLanguageDownload: true)
        #expect(estimate.transcription == 120)
        #expect(estimate.adDetection == 60)
        #expect(estimate.processing == 180)
        #expect(estimate.downloadBytes == 50_000_000)
        #expect(estimator.estimate(duration: 3600, detectAds: false).adDetection == 0)
    }

    @Test func blendsMeasurements() {
        #expect(TimeEstimator.blended(20, with: 40, isFirst: true) == 40)
        #expect(abs(TimeEstimator.blended(20, with: 40, isFirst: false) - 27) < 0.001)
        #expect(TimeEstimator.blended(20, with: .nan, isFirst: false) == 20)
    }

    @Test func remainingTimeUsesTheMeasuredRateOnceMeaningful() {
        #expect(TimeEstimator.remaining(done: 100, total: 1000, elapsed: 2, fallbackRate: 20) == 45)
        #expect(TimeEstimator.remaining(done: 100, total: 1000, elapsed: 10, fallbackRate: 20) == 90)
        #expect(TimeEstimator.remaining(done: 1000, total: 1000, elapsed: 10, fallbackRate: 20) == 0)
    }
}

@Suite struct TranscriptionHelperTests {
    @Test func splitsResultsIntoSentences() {
        let words = "Welcome back to the show. This episode is brought to you by Acme. Go!".split(separator: " ").enumerated().map { index, word in
            TranscriptWord(text: String(word), start: Double(index), end: Double(index) + 0.8)
        }
        let sentences = SpeechTranscriptionEngine.sentences(of: TranscriptSegment(start: 0, end: 20, text: "", words: words))
        #expect(sentences.map(\.text) == ["Welcome back to the show.", "This episode is brought to you by Acme. Go!"])
        #expect(sentences.map(\.start) == [0, 5])
        #expect(sentences[0].end == 4.8)
        #expect(sentences[1].end == 20)
        #expect(SpeechTranscriptionEngine.sentences(of: TranscriptSegment(start: 0, end: 1, text: "Hi.", words: [TranscriptWord(text: "Hi.", start: 0, end: 1)])).count == 1)
    }

    @Test func mapsFeedLanguagesToLocales() {
        #expect(TranscriptionService.localeIdentifier(forLanguage: "German") == "de-DE")
        #expect(TranscriptionService.localeIdentifier(forLanguage: "en_us") == "en-us")
        #expect(TranscriptionService.localeIdentifier(forLanguage: " de ") == "de")
    }

    @Test func buildsWordsFromTimedTokens() throws {
        func token(_ text: String, _ start: Double, _ end: Double) -> AttributedString {
            var string = AttributedString(text)
            string.audioTimeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 1000), end: CMTime(seconds: end, preferredTimescale: 1000))
            return string
        }
        var text = token("Werbe", 1, 1.3)
        text += token("partner", 1.3, 1.6)
        text += token(" sind", 1.7, 2.0)
        text += AttributedString(",")
        text += token(" toll", 2.1, 2.5)
        text += token(".", 2.5, 2.6)
        let range = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 1000), end: CMTime(seconds: 2.6, preferredTimescale: 1000))
        let segment = try #require(SpeechTranscriptionEngine.segment(from: text, range: range, offset: 100))
        #expect(segment.words.map(\.text) == ["Werbepartner", "sind,", "toll."])
        #expect(segment.text == "Werbepartner sind, toll.")
        #expect(segment.words[0].start == 101)
        #expect(abs(segment.words[0].end - 101.6) < 0.001)
        #expect(abs(segment.words[2].end - 102.5) < 0.001)
        #expect(segment.start == 101)
    }
}
