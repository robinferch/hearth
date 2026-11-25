import Foundation
import HearthModel
import Testing
@testable import HearthIntelligence

/// Runs the real on-device pipeline on synthesized speech (`say`). Opt-in because it may download a speech model:
/// `HEARTH_SPEECH_TESTS=1 swift test --filter SpeechIntegrationTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HEARTH_SPEECH_TESTS"] != nil))
struct SpeechIntegrationTests {
    static let script = """
        Welcome back to the show. Today we talk about how coffee is roasted and why freshness matters so much. \
        This episode is brought to you by Acme Coffee. Go to acme coffee dot com and use code SHOW for twenty percent off your first order. \
        And now back to the show. Roasting starts with green beans that are heated until they crack.
        """

    @Test func transcribesWithWordTimingsAndFindsTheAd() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "hearth-speech-\(UUID().uuidString).aiff")
        let say = Process()
        say.executableURL = URL(filePath: "/usr/bin/say")
        say.arguments = ["-o", url.path, Self.script]
        try say.run()
        say.waitUntilExit()
        defer { try? FileManager.default.removeItem(at: url) }

        let locale = try #require(await SpeechTranscriptionEngine.supportedLocale(for: Locale(identifier: "en-US")))
        try await SpeechTranscriptionEngine.prepare(locale) { _ in }

        let processed = Mutex<TimeInterval>(0)
        let started = Date.now
        let segments = try await SpeechTranscriptionEngine.transcribe(
            tracks: [AudioTrack(index: 0, offset: 10, duration: 40, url: url)],
            locale: locale
        ) { seconds in processed.withLock { $0 = max($0, seconds) } }
        let elapsed = Date.now.timeIntervalSince(started)

        let text = segments.map(\.text).joined(separator: " ")
        print("Transcribed in \(elapsed) s: \(text)")
        #expect(text.localizedCaseInsensitiveContains("coffee"))
        let words = segments.flatMap(\.words)
        #expect(words.count > 30)
        // Absolute times: the track starts at 10 s.
        #expect(words.allSatisfy { $0.start >= 10 && $0.end >= $0.start })
        #expect(zip(words, words.dropFirst()).allSatisfy { $0.start <= $1.start })
        #expect(processed.withLock { $0 } >= 40)

        let transcript = Transcript(itemID: ItemIdentifier(kind: .episode, connectionID: "c", libraryID: "l", primaryID: "e", groupingID: "p"), localeIdentifier: locale.identifier(.bcp47), duration: 50, segments: segments)
        let analysis = try await AdDetector().detect(in: transcript)
        print("Ads (\(analysis.method)): \(analysis.segments)")
        let sponsorWord = try #require(words.first { $0.text.localizedCaseInsensitiveContains("Acme") })
        #expect(analysis.segments.contains { $0.start <= sponsorWord.start + 1 && sponsorWord.start <= $0.end })
        // The episode around the ad isn't skipped.
        let welcome = try #require(words.first { $0.text.localizedCaseInsensitiveContains("Welcome") })
        let roasting = try #require(words.first { $0.text.localizedCaseInsensitiveContains("Roasting") })
        #expect(!analysis.segments.contains { $0.contains(welcome.start) || $0.contains(roasting.start) })
    }
}

import Synchronization
