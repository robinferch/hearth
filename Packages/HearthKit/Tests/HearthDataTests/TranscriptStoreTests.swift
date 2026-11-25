import Foundation
@testable import HearthData
import HearthModel
import Testing

@Suite("Transcripts & new episodes")
@MainActor
struct TranscriptStoreTests {
    @Test func storesTranscriptsAndAdsAcrossLaunches() async throws {
        let client = MockClient(connection: Fixtures.connection())
        let hearth = makeHearth([client])
        let id = Fixtures.episodeID("e1", podcast: "p", connection: client.connection.id)
        let transcript = Transcript(itemID: id, localeIdentifier: "de-DE", createdAt: Date(timeIntervalSince1970: 1_700_000_000), duration: 30, segments: [
            TranscriptSegment(start: 0, end: 4, text: "Hallo Welt", words: [TranscriptWord(text: "Hallo", start: 0, end: 1), TranscriptWord(text: "Welt", start: 1, end: 2)]),
        ])
        try await hearth.transcripts.save(transcript)
        hearth.transcripts.saveAds(AdAnalysis(itemID: id, method: .heuristic, segments: [AdSegment(id: 0, start: 10, end: 20, confidence: 0.7)]))
        #expect(hearth.transcripts.hasTranscript(id))
        #expect(hearth.transcripts.entry(for: id)?.wordCount == 2)

        let reloaded = TranscriptStore(environment: hearth.environment)
        #expect(reloaded.hasTranscript(id))
        #expect(await reloaded.transcript(for: id) == transcript)
        #expect(reloaded.adSegments(for: id).map(\.start) == [10])
        #expect(await reloaded.storageUsed() > 0)

        reloaded.forget(connection: client.connection.id)
        #expect(!reloaded.hasTranscript(id))
        #expect(reloaded.adSegments(for: id).isEmpty)
        #expect(await reloaded.transcript(for: id) == nil)
    }

    @Test func announcesOnlyNewRecentEpisodesAfterTheBaseline() throws {
        let defaults = try #require(UserDefaults(suiteName: "me.robinferch.hearth.tests.\(UUID().uuidString)"))
        let tracker = NewEpisodeTracker(defaults: defaults)
        let library = LibraryIdentifier(connectionID: "c", libraryID: "pods")
        let now = Date.now
        func episode(_ id: String, daysAgo: Double) -> Episode {
            Episode(id: Fixtures.episodeID(id, podcast: "p", connection: "c"), name: id, podcastName: "Pod", publishedAt: now.addingTimeInterval(-daysAgo * 86_400))
        }

        #expect(tracker.register([episode("a", daysAgo: 3), episode("b", daysAgo: 10)], in: library, now: now).isEmpty)
        #expect(tracker.hasBaseline(for: library))

        let new = tracker.register([episode("d", daysAgo: 0.5), episode("c", daysAgo: 0.1), episode("old", daysAgo: 40), episode("a", daysAgo: 3)], in: library, now: now)
        #expect(new.map(\.name) == ["c", "d"])
        #expect(tracker.register([episode("c", daysAgo: 0.1)], in: library, now: now).isEmpty)

        tracker.reset()
        #expect(!tracker.hasBaseline(for: library))
    }
}
