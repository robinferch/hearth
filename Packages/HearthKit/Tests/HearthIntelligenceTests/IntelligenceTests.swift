import CoreMedia
import Foundation
import HearthModel
import Speech
import Synchronization
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
        let ads = AdDetector.adSegments(from: [
            AdBlockCandidate(firstLine: 3, lastLine: 5, advertiser: "Acme"),
            AdBlockCandidate(firstLine: 8, lastLine: 8),
            AdBlockCandidate(firstLine: 12, lastLine: 99, advertiser: " "),
            AdBlockCandidate(firstLine: 10, lastLine: 2),
        ], window: 0 ..< 15, segments: segments)
        #expect(ads.map(\.start) == [30, 80, 120, 100])
        #expect(ads.map(\.end) == [60, 90, 150, 110])
        #expect(ads[0].advertiser == "Acme")
        #expect(ads[2].advertiser == nil)
        let tooLong = AdDetector.adSegments(from: [AdBlockCandidate(firstLine: 0, lastLine: 14)], window: 0 ..< 15, segments: (0 ..< 15).map { segment(Double($0) * 60, Double($0) * 60 + 60, "x") })
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

/// A scripted model for the detector.
private struct ScriptedRunner: AdModelRunner {
    var method: AdAnalysis.Method = .localModel
    var modelName: String? = "Test Model"
    var windowCharacters: Int
    var readsCandidatesOnly = false
    var timeBudget: TimeInterval?
    var extendsToCuePassages = false
    var delay: Duration = .zero
    let answer: @Sendable (String) throws -> [AdBlockCandidate]

    func findAds(instructions: String, transcript: String) async throws -> [AdBlockCandidate] {
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        return try answer(transcript)
    }
}

@Suite struct AdDetectorRunnerTests {
    static let transcript = Transcript(
        itemID: ItemIdentifier(kind: .episode, connectionID: "c", libraryID: "l", primaryID: "e", groupingID: "p"),
        localeIdentifier: "de-DE",
        duration: 300,
        segments: (0 ..< 30).map { segment(Double($0) * 10, Double($0) * 10 + 10, $0 == 20 ? "Mit dem Rabattcode HEARTH spart ihr zwanzig Prozent, präsentiert von Acme." : "Satz Nummer \($0) über Kaffee und Röstung.") }
    )

    @Test func asksTheModelPerWindowAndRecordsTheModel() async throws {
        let prompts = Mutex<[String]>([])
        let runner = ScriptedRunner(windowCharacters: 500) { prompt in
            prompts.withLock { $0.append(prompt) }
            return prompt.contains("[3]") ? [AdBlockCandidate(firstLine: 3, lastLine: 5, advertiser: "Acme")] : []
        }
        let analysis = try await AdDetector().detect(in: Self.transcript, runner: runner)
        #expect(prompts.withLock { $0.count } > 1)
        #expect(prompts.withLock { $0[0] }.hasPrefix("Transcript lines 0 to "))
        #expect(analysis.method == .localModel)
        #expect(analysis.modelName == "Test Model")
        #expect(analysis.segments.map(\.start) == [30])
        #expect(analysis.segments.first?.end == 60)
    }

    @Test func windowsTheModelCanNotHandleUseKeywords() async throws {
        let runner = ScriptedRunner(windowCharacters: 100_000) { _ in throw AnthropicError.refused }
        let analysis = try await AdDetector().detect(in: Self.transcript, runner: runner)
        #expect(analysis.method == .localModel)
        #expect(analysis.segments.contains { $0.contains(205) })
    }

    @Test func aWrongKeyStopsTheDetection() async {
        let runner = ScriptedRunner(method: .anthropic, windowCharacters: 100_000) { _ in throw AnthropicError.invalidAPIKey }
        await #expect(throws: AnthropicError.invalidAPIKey) {
            try await AdDetector().detect(in: Self.transcript, runner: runner)
        }
    }

    @Test func withoutAModelKeywordsAreUsed() async throws {
        let analysis = try await AdDetector().detect(in: Self.transcript, runner: nil)
        #expect(analysis.method == .heuristic)
        #expect(analysis.modelName == nil)
    }
}

@Suite struct AnthropicAPITests {
    @Test func buildsAStructuredOutputRequestWithRefusalFallback() throws {
        let opus = try #require(AnthropicModel.model(id: "claude-opus-5-5"))
        let request = try AnthropicAPI.messagesRequest(apiKey: "sk-test", model: opus, instructions: "Find ads.", transcript: "[0] Hallo")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        let httpBody = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(body["system"] as? String == "Find ads.")
        #expect(body["fallbacks"] as? String == "default")
        #expect(body["thinking"] == nil)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.first?["role"] as? String == "user")
        #expect(messages.first?["content"] as? String == "[0] Hallo")
        let format = try #require((body["output_config"] as? [String: Any])?["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let schema = try #require(format["schema"] as? [String: Any])
        #expect(schema["additionalProperties"] as? Bool == false)
    }

    @Test func haikuHasNoServerSideFallback() throws {
        let haiku = try #require(AnthropicModel.model(id: "claude-haiku-5-5"))
        let request = try AnthropicAPI.messagesRequest(apiKey: "k", model: haiku, instructions: "i", transcript: "t")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == nil)
        let httpBody = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        #expect(body["fallbacks"] == nil)
    }

    @Test func parsesTheAnswerAndSkipsThinkingBlocks() throws {
        let data = Data(#"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"{\"ads\":[{\"firstLine\":4,\"lastLine\":9,\"advertiser\":\"Aldi\"},{\"firstLine\":20,\"lastLine\":22,\"advertiser\":null}]}"}],"stop_reason":"end_turn"}"#.utf8)
        #expect(try AnthropicAPI.parseAds(from: data) == [
            AdBlockCandidate(firstLine: 4, lastLine: 9, advertiser: "Aldi"),
            AdBlockCandidate(firstLine: 20, lastLine: 22, advertiser: nil),
        ])
    }

    @Test func refusalsAndErrorsAreReported() {
        let refusal = Data(#"{"content":[],"stop_reason":"refusal"}"#.utf8)
        #expect(throws: AnthropicError.refused) { try AnthropicAPI.parseAds(from: refusal) }
        #expect(AnthropicAPI.error(status: 401, data: Data()) == .invalidAPIKey)
        let credit = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low."}}"#.utf8)
        #expect(AnthropicAPI.error(status: 400, data: credit) == .rejected("Your credit balance is too low."))
        #expect(AnthropicAPI.error(status: 529, data: Data()) == .overloaded)
        #expect(AnthropicError.invalidAPIKey.isFatal && !AnthropicError.overloaded.isFatal)
    }

    @Test func validatesKeysWithAFreeRequest() {
        let request = AnthropicAPI.validationRequest(apiKey: "sk-test")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/models?limit=1")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
    }
}

@Suite struct ProviderEstimateTests {
    @Test func largerWindowsNeedFewerRequests() {
        #expect(TimeEstimator.adWindowCount(forDuration: 3600, windowCharacters: 4_500) == 12)
        #expect(TimeEstimator.adWindowCount(forDuration: 3600, windowCharacters: 9_000) == 6)
        #expect(TimeEstimator.adWindowCount(forDuration: 3600, windowCharacters: 300_000) == 1)
        let estimator = TimeEstimator(transcriptionSpeed: 40, secondsPerAdWindow: 45)
        #expect(estimator.estimate(duration: 3600, detectAds: true, adWindowCharacters: 300_000).adDetection == 45)
    }

    @Test func localModelsAreListedWithTheRecommendationFirst() {
        #expect(LocalAdModel.all.first?.isRecommended == true)
        #expect(Set(LocalAdModel.all.map(\.id)).count == LocalAdModel.all.count)
        #expect(LocalAdModel.model(id: "gemma-4-e2b")?.repository == "mlx-community/gemma-4-e2b-it-4bit")
        #expect(AnthropicModel.all.first?.id == "claude-opus-5-5")
    }

    @Test func hiddenLocalModelsCountAsAutomatic() {
        #expect(!AdDetectionProvider.selectable.contains(.localModel))
        #expect(AdDetectionProvider(setting: "localModel") == .automatic)
        #expect(AdDetectionProvider(setting: "anthropic") == .anthropic)
        #expect(AdDetectionProvider(setting: "unknown") == .automatic)
    }
}

@Suite struct CandidateSelectionTests {
    static func talk(_ count: Int, from start: Int = 0) -> [TranscriptSegment] {
        (0 ..< count).map { segment(Double(start + $0) * 10, Double(start + $0) * 10 + 10, "Wir reden heute über das Wetter und den Garten, Satz \(start + $0).") }
    }

    @Test func selectsSponsorReadsAndCommercialsWithContext() {
        var segments = Self.talk(20)
        segments[10] = segment(100, 110, "Online-Geschenke shoppen mit PayPal ist jetzt noch smarter, denn mit der Bezahlung kannst du dir Zeit lassen.")
        segments[17] = segment(170, 180, "Mit dem Rabattcode HEARTH bekommt ihr zehn Prozent.")
        let regions = CandidateSelector().regions(in: segments)
        #expect(regions == [7 ..< 20])
        #expect(CandidateSelector().regions(in: Self.talk(30)).isEmpty)
    }

    @Test func modelBlocksNeverSpanTheGapBetweenPassages() {
        var segments = Self.talk(60)
        segments[10] = segment(100, 110, "Mit dem Rabattcode HEARTH bekommt ihr zehn Prozent.")
        segments[50] = segment(500, 510, "Diese Folge wird präsentiert von Acme, jetzt bestellen.")
        let runner = ScriptedRunner(windowCharacters: 100_000, readsCandidatesOnly: true) { _ in [] }
        let windows = AdDetector.requestWindows(for: segments, runner: runner, overlap: 2)
        #expect(windows == [[7 ..< 14, 47 ..< 54]])
        let prompt = AdDetector.prompt(for: windows[0], segments: segments)
        #expect(prompt.contains("[13] "))
        #expect(prompt.contains("\n…\n[47] "))
        #expect(!prompt.contains("[20] "))
        // A block from line 9 to 51 would skip lines 14–46, which the model never saw: cut at the passage end.
        let ads = AdDetector.adSegments(from: [AdBlockCandidate(firstLine: 9, lastLine: 51)], regions: windows[0], segments: segments)
        #expect(ads.map(\.start) == [90])
        #expect(ads.map(\.end) == [140])
    }

    @Test func candidateRunnersOnlyReadThePassages() async throws {
        var segments = Self.talk(200)
        segments[100] = segment(1000, 1010, "Mit dem Rabattcode HEARTH bekommt ihr zehn Prozent bei Acme, jetzt sichern.")
        let transcript = Transcript(itemID: AdDetectorRunnerTests.transcript.itemID, localeIdentifier: "de-DE", duration: 2000, segments: segments)
        let prompts = Mutex<[String]>([])
        let runner = ScriptedRunner(windowCharacters: 9_000, readsCandidatesOnly: true) { prompt in
            prompts.withLock { $0.append(prompt) }
            return [AdBlockCandidate(firstLine: 99, lastLine: 101, advertiser: "Acme")]
        }
        let analysis = try await AdDetector().detect(in: transcript, runner: runner)
        #expect(prompts.withLock { $0.count } == 1)
        #expect(prompts.withLock { $0[0] }.split(separator: "\n").count == 8)
        #expect(analysis.segments.map(\.start) == [990])
    }

    @Test func pastTheTimeBudgetKeywordsAreUsed() async throws {
        let calls = Mutex(0)
        let runner = ScriptedRunner(windowCharacters: 500, timeBudget: 0) { _ in
            calls.withLock { $0 += 1 }
            return []
        }
        let analysis = try await AdDetector().detect(in: AdDetectorRunnerTests.transcript, runner: runner)
        #expect(calls.withLock { $0 } == 0)
        #expect(analysis.segments.contains { $0.contains(205) })
    }

    @Test func aSlowRequestIsCancelledAtTheDeadline() async throws {
        let runner = ScriptedRunner(windowCharacters: 100_000, timeBudget: 0.2, delay: .seconds(30)) { _ in
            [AdBlockCandidate(firstLine: 0, lastLine: 29)]
        }
        let clock = ContinuousClock()
        let start = clock.now
        let analysis = try await AdDetector().detect(in: AdDetectorRunnerTests.transcript, runner: runner)
        #expect(clock.now - start < .seconds(5))
        // Keywords took over.
        #expect(analysis.segments.contains { $0.contains(205) })
    }

    @Test func blocksWidenToTheCueLinesOfTheirPassage() async throws {
        var segments = Self.talk(60)
        segments[20] = segment(200, 210, "Diese Folge wird präsentiert von Acme.")
        segments[22] = segment(220, 230, "Mit dem Rabattcode HEARTH bekommt ihr zehn Prozent, jetzt sichern.")
        segments[24] = segment(240, 250, "Es gelten die Bedingungen auf acme punkt de.")
        let transcript = Transcript(itemID: AdDetectorRunnerTests.transcript.itemID, localeIdentifier: "de-DE", duration: 600, segments: segments)
        // The model only marks the line with the code.
        let answer: @Sendable (String) throws -> [AdBlockCandidate] = { _ in [AdBlockCandidate(firstLine: 22, lastLine: 22, advertiser: "Acme")] }
        let widened = try await AdDetector().detect(in: transcript, runner: ScriptedRunner(windowCharacters: 9_000, readsCandidatesOnly: true, extendsToCuePassages: true, answer: answer))
        #expect(widened.segments.map(\.start) == [200])
        #expect(widened.segments.map(\.end) == [250])
        let plain = try await AdDetector().detect(in: transcript, runner: ScriptedRunner(windowCharacters: 9_000, readsCandidatesOnly: true, answer: answer))
        #expect(plain.segments.map(\.start) == [220])
    }
}

@Suite struct TextAnswerTests {
    @Test func readsLenientPlainTextAnswers() {
        let blocks = AdDetector.parseTextAnswer("""
            120-131 Acme
            [140 - 150] PayPal. The block starts with …
            12-12, -
            301–305 NONE
            NONE
            """)
        #expect(blocks == [
            AdBlockCandidate(firstLine: 120, lastLine: 131, advertiser: "Acme"),
            AdBlockCandidate(firstLine: 140, lastLine: 150, advertiser: "PayPal"),
            AdBlockCandidate(firstLine: 12, lastLine: 12, advertiser: nil),
            AdBlockCandidate(firstLine: 301, lastLine: 305, advertiser: nil),
        ])
        #expect(AdDetector.parseTextAnswer("NONE").isEmpty)
        #expect(AdDetector.parseTextAnswer("50-40 Backwards").isEmpty)
    }
}
