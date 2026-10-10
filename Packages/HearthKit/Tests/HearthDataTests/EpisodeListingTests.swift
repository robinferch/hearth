import Foundation
@testable import HearthData
import HearthAPI
import HearthModel
import Testing

@Suite("Episode filter & sort")
struct EpisodeListingTests {
    let connection = "conn"

    var episodes: [Episode] {
        [
            Fixtures.episode("e1", connection: connection, name: "Bravo", season: "1", number: "2", published: Fixtures.date(200), duration: 300),
            Fixtures.episode("e2", connection: connection, name: "alpha", season: "1", number: "10", published: Fixtures.date(100), duration: 100),
            Fixtures.episode("e3", connection: connection, name: "Charlie", season: "2", number: "1", published: Fixtures.date(300), duration: 200),
            Fixtures.episode("e4", connection: connection, name: "Delta", season: "1", number: "1", published: Fixtures.date(50), duration: 400),
        ]
    }

    func apply(_ settings: EpisodeListSettings, progress: [String: ProgressEntity] = [:], downloaded: Set<String> = []) -> [String] {
        EpisodeListing.apply(settings, to: episodes, progress: { progress[$0.primaryID] }, isDownloaded: { downloaded.contains($0.primaryID) }).map(\.id.primaryID)
    }

    @Test func sortsByIndexNaturally() {
        #expect(apply(EpisodeListSettings(sort: .index, direction: .ascending, filter: .all)) == ["e4", "e1", "e2", "e3"])
        #expect(apply(EpisodeListSettings(sort: .index, direction: .descending, filter: .all)) == ["e3", "e2", "e1", "e4"])
    }

    @Test func sortsByReleaseNameAndDuration() {
        #expect(apply(EpisodeListSettings(sort: .released, direction: .descending, filter: .all)) == ["e3", "e1", "e2", "e4"])
        #expect(apply(EpisodeListSettings(sort: .name, direction: .ascending, filter: .all)) == ["e2", "e1", "e3", "e4"])
        #expect(apply(EpisodeListSettings(sort: .duration, direction: .ascending, filter: .all)) == ["e2", "e3", "e1", "e4"])
    }

    @Test func filtersByProgress() {
        let progress = [
            "e1": Fixtures.progress(Fixtures.episodeID("e1", podcast: "pod", connection: connection), currentTime: 100, duration: 100, lastUpdate: Fixtures.date(0)),
            "e2": Fixtures.progress(Fixtures.episodeID("e2", podcast: "pod", connection: connection), currentTime: 30, duration: 100, lastUpdate: Fixtures.date(0)),
        ]
        let sort = EpisodeListSettings(sort: .released, direction: .ascending, filter: .all)
        var settings = sort
        settings.filter = .finished
        #expect(apply(settings, progress: progress) == ["e1"])
        settings.filter = .inProgress
        #expect(apply(settings, progress: progress) == ["e2"])
        settings.filter = .notStarted
        #expect(apply(settings, progress: progress) == ["e4", "e3"])
        settings.filter = .notFinished
        #expect(apply(settings, progress: progress) == ["e4", "e2", "e3"])
    }

    @Test func filtersBySeasonAndDownloads() {
        let season = EpisodeListSettings(sort: .index, direction: .ascending, filter: .all, season: "1")
        #expect(apply(season) == ["e4", "e1", "e2"])
        let downloaded = EpisodeListSettings(sort: .index, direction: .ascending, filter: .all, downloadedOnly: true)
        #expect(apply(downloaded, downloaded: ["e3", "e1"]) == ["e1", "e3"])
    }

    @Test func defaultFilterIsNotFinished() {
        #expect(EpisodeListSettings(sort: .released, direction: .descending).filter == .notFinished)
    }

    @Test func seasonsAreNaturallySorted() {
        let list = episodes + [Fixtures.episode("e5", connection: connection, season: "10")]
        #expect(EpisodeListing.seasons(in: list) == ["1", "2", "10"])
    }

    @MainActor
    @Test func storeDefaultsFollowSettingsAndSerialPodcasts() {
        let hearth = makeHearth([MockClient(connection: Fixtures.connection())])
        hearth.settings.defaultEpisodeSort = .duration
        hearth.settings.defaultEpisodeSortDirection = .ascending
        let podcastID = ItemIdentifier(kind: .podcast, connectionID: "conn", libraryID: "pods", primaryID: "pod")
        #expect(hearth.itemSettings.episodeListSettings(for: podcastID) == EpisodeListSettings(sort: .duration, direction: .ascending))

        let serial = Podcast(id: podcastID, name: "Serial", publishingType: .serial)
        #expect(hearth.itemSettings.episodeListSettings(for: serial).sort == .index)

        let custom = EpisodeListSettings(sort: .name, direction: .descending, filter: .all)
        hearth.itemSettings.setEpisodeListSettings(custom, for: podcastID)
        #expect(hearth.itemSettings.episodeListSettings(for: serial) == custom)
    }
}
