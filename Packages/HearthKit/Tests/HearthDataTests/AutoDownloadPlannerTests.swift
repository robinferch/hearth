import Foundation
@testable import HearthData
import HearthAPI
import HearthModel
import Testing

@Suite("Auto-download rules")
struct AutoDownloadPlannerTests {
    let connection = "conn"

    func id(_ name: String) -> ItemIdentifier {
        Fixtures.episodeID(name, podcast: "pod", connection: connection)
    }

    var candidates: [AutoDownloadPlanner.Candidate] {
        [
            .init(id: id("e1"), isFinished: true, released: Fixtures.date(0)),
            .init(id: id("e2"), isFinished: false, released: Fixtures.date(-3 * 3600)),
            .init(id: id("e3"), isFinished: false, released: Fixtures.date(-30 * 3600)),
            .init(id: id("e4"), isFinished: false, released: nil),
        ]
    }

    @Test func selectsPerRule() {
        let now = Fixtures.date(0)
        #expect(AutoDownloadPlanner.select(.disabled, candidates: candidates, now: now).isEmpty)
        #expect(AutoDownloadPlanner.select(.all, candidates: candidates, now: now) == [id("e2"), id("e3"), id("e4")])
        #expect(AutoDownloadPlanner.select(.nextUnfinished(count: 2), candidates: candidates, now: now) == [id("e2"), id("e3")])
        #expect(AutoDownloadPlanner.select(.releasedWithin(hours: 24), candidates: candidates, now: now) == [id("e2")])
        #expect(AutoDownloadPlanner.select(.releasedWithin(hours: 48), candidates: candidates, now: now) == [id("e2"), id("e3")])
    }

    @Test func downloadsMissingAndTracksThem() {
        let changes = AutoDownloadPlanner.reconcile(desired: ["rule": [id("a"), id("b")]], tracked: [:], present: [id("b")], locked: [], finished: [], removeFinished: true)
        #expect(changes.download == [id("a")])
        // `b` was downloaded manually: never tracked, never removed by rules.
        #expect(changes.track == [.init(ruleKey: "rule", itemID: id("a"))])
        #expect(changes.remove.isEmpty)
    }

    @Test func removesItemsNoLongerCovered() {
        let changes = AutoDownloadPlanner.reconcile(desired: ["rule": [id("b")]], tracked: ["rule": [id("a"), id("b")]], present: [id("a"), id("b")], locked: [], finished: [], removeFinished: true)
        #expect(changes.download.isEmpty)
        #expect(changes.untrack == [.init(ruleKey: "rule", itemID: id("a"))])
        #expect(changes.remove == [id("a")])
    }

    @Test func keepsItemsCoveredByAnotherRule() {
        let changes = AutoDownloadPlanner.reconcile(desired: ["series": []], tracked: ["series": [id("a")], "listen-now": [id("a")]], present: [id("a")], locked: [], finished: [], removeFinished: true)
        #expect(changes.untrack == [.init(ruleKey: "series", itemID: id("a"))])
        #expect(changes.remove.isEmpty)
    }

    @Test func rulesThatFailedToLoadKeepTheirItems() {
        // Only "b" was evaluated; "a"'s items stay untouched.
        let changes = AutoDownloadPlanner.reconcile(desired: ["b": []], tracked: ["a": [id("x")], "b": []], present: [id("x")], locked: [], finished: [], removeFinished: true)
        #expect(changes == AutoDownloadPlanner.Changes())
    }

    @Test func lockedItemsAreNotRemoved() {
        let changes = AutoDownloadPlanner.reconcile(desired: ["rule": []], tracked: ["rule": [id("a")]], present: [id("a")], locked: [id("a")], finished: [], removeFinished: true)
        #expect(changes.remove.isEmpty)
        #expect(changes.untrack.isEmpty)
    }

    @Test func finishedItemsStayWhenRemovalDisabled() {
        let keep = AutoDownloadPlanner.reconcile(desired: ["rule": []], tracked: ["rule": [id("a")]], present: [id("a")], locked: [], finished: [id("a")], removeFinished: false)
        #expect(keep.remove.isEmpty)
        #expect(keep.untrack.count == 1)
        let remove = AutoDownloadPlanner.reconcile(desired: ["rule": []], tracked: ["rule": [id("a")]], present: [id("a")], locked: [], finished: [id("a")], removeFinished: true)
        #expect(remove.remove == [id("a")])
    }

    @Test func sharedItemsAreTrackedByBothRules() {
        let changes = AutoDownloadPlanner.reconcile(desired: ["b": [id("a")]], tracked: ["a": [id("a")]], present: [id("a")], locked: [], finished: [], removeFinished: true)
        #expect(changes.download.isEmpty)
        #expect(changes.track == [.init(ruleKey: "b", itemID: id("a"))])
    }

    @Test func assetWeights() {
        let book = Fixtures.bookID("b", connection: connection)
        let details = PlayableItemDetails(
            item: .audiobook(Fixtures.book("b", connection: connection)),
            audioFiles: [
                AudioFile(ino: "2", fileExtension: ".mp3", offset: 100, duration: 300),
                AudioFile(ino: "1", fileExtension: ".mp3", offset: 0, duration: 100),
            ],
            chapters: [],
            pdfs: [PDFFile(ino: "p", name: "Booklet")],
            progress: nil
        )
        let assets = DownloadManager.makeAssets(for: book, details: details)
        let total = assets.reduce(0) { $0 + $1.weight }
        #expect(abs(total - 100) < 0.0001)
        #expect(abs(assets.filter { $0.kind == .cover }.reduce(0) { $0 + $1.weight } - 10) < 0.0001)
        let audio = assets.filter { $0.kind == .audio }
        #expect(audio.map(\.ino) == ["1", "2"])
        #expect(abs(audio[0].weight - 20) < 0.0001)
        #expect(abs(audio[1].weight - 60) < 0.0001)
        #expect(audio[1].relativePath == "conn/books/b/audio-1.mp3")
    }

    @Test func taskDescriptionRoundTrip() {
        let description = DownloadTaskDescription(assetID: "abc", relativePath: "c/l/p/audio-0.m4b")
        #expect(DownloadTaskDescription(description.encoded) == description)
        #expect(DownloadTaskDescription("garbage") == nil)
    }
}
