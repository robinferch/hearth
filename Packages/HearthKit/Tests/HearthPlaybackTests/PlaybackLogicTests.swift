import Foundation
import HearthModel
import Testing
@testable import HearthPlayback

private func track(_ index: Int, _ offset: TimeInterval, _ duration: TimeInterval) -> AudioTrack {
    AudioTrack(index: index, offset: offset, duration: duration, url: URL(string: "https://example.com/\(index).mp3")!)
}

private func chapter(_ id: Int, _ start: TimeInterval, _ end: TimeInterval) -> Chapter {
    Chapter(id: id, start: start, end: end, title: "Chapter \(id)")
}

@Suite struct PlaybackTimelineTests {
    let timeline = PlaybackTimeline(tracks: [track(1, 100, 50), track(0, 0, 100), track(2, 150, 30)])

    @Test func sortsAndComputesDuration() {
        #expect(timeline.tracks.map(\.index) == [0, 1, 2])
        #expect(timeline.duration == 180)
    }

    @Test func mapsTimeToTracks() {
        #expect(timeline.position(containing: 0) == 0)
        #expect(timeline.position(containing: 99.9) == 0)
        #expect(timeline.position(containing: 100) == 1)
        #expect(timeline.position(containing: 179) == 2)
        #expect(timeline.localTime(for: 120, at: 1) == 20)
        #expect(timeline.absoluteTime(local: 10, at: 2) == 160)
    }

    @Test func seekPlans() {
        #expect(timeline.seekPlan(to: 20, loadedPositions: [0, 1, 2]) == .withinCurrent(localTime: 20))
        #expect(timeline.seekPlan(to: 160, loadedPositions: [0, 1, 2]) == .advance(steps: 2, localTime: 10))
        #expect(timeline.seekPlan(to: 10, loadedPositions: [1, 2]) == .rebuild(fromPosition: 0, localTime: 10))
        #expect(timeline.seekPlan(to: 180, loadedPositions: [0, 1, 2]) == .finish)
        #expect(timeline.seekPlan(to: -5, loadedPositions: []) == .rebuild(fromPosition: 0, localTime: 0))
        #expect(PlaybackTimeline.empty.seekPlan(to: 0, loadedPositions: []) == .finish)
    }
}

@Suite struct ChapterLookupTests {
    let chapters = [chapter(0, 0, 60), chapter(1, 60, 120), chapter(2, 120, 200)]

    @Test func findsChapter() {
        #expect(ChapterLookup.index(of: 0, in: chapters) == 0)
        #expect(ChapterLookup.index(of: 59.99, in: chapters) == 1) // within tolerance of the next start
        #expect(ChapterLookup.index(of: 59.5, in: chapters) == 0)
        #expect(ChapterLookup.index(of: 150, in: chapters) == 2)
        #expect(ChapterLookup.index(of: 500, in: chapters) == 2)
        #expect(ChapterLookup.index(of: 5, in: []) == nil)
    }

    @Test func previousAndNext() {
        #expect(ChapterLookup.previousTarget(from: 65, in: chapters) == 60)
        #expect(ChapterLookup.previousTarget(from: 62, in: chapters) == 0)
        #expect(ChapterLookup.previousTarget(from: 1, in: chapters) == 0)
        #expect(ChapterLookup.nextStart(from: 10, in: chapters) == 60)
        #expect(ChapterLookup.nextStart(from: 150, in: chapters) == nil)
    }

    @Test func normalizesEnds() {
        let fixed = ChapterLookup.normalized([chapter(1, 50, 0), chapter(0, 0, 0)], duration: 90)
        #expect(fixed.map(\.start) == [0, 50])
        #expect(fixed.map(\.end) == [50, 90])
    }

    @Test func chaptersRemaining() {
        #expect(ChapterLookup.chaptersRemaining(until: 3, currentIndex: 1) == 3)
        #expect(ChapterLookup.chaptersRemaining(until: 0, currentIndex: 2) == 1)
    }
}

@Suite struct SleepTimerMathTests {
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let config = SleepTimerExtendConfiguration(extendByPrevious: true, extendMinutes: 20, extendChapters: 1)

    @Test func presets() {
        #expect(SleepTimerMath.state(for: .minutes(5), now: now) == .duration(deadline: now.addingTimeInterval(300), original: 300))
        #expect(SleepTimerMath.state(for: .endOfChapter, now: now) == .chapters(remaining: 1, original: 1))
    }

    @Test func remainingIsFrozenWhilePaused() {
        let state = SleepTimerState.duration(deadline: now.addingTimeInterval(100), original: 100)
        #expect(SleepTimerMath.remaining(of: state, now: now.addingTimeInterval(30), pausedAt: nil) == 70)
        #expect(SleepTimerMath.remaining(of: state, now: now.addingTimeInterval(500), pausedAt: now.addingTimeInterval(30)) == 70)
        let resumed = SleepTimerMath.resumed(state, pausedAt: now.addingTimeInterval(30), now: now.addingTimeInterval(90))
        #expect(SleepTimerMath.remaining(of: resumed, now: now.addingTimeInterval(90), pausedAt: nil) == 70)
    }

    @Test func extend() {
        let duration = SleepTimerState.duration(deadline: now.addingTimeInterval(60), original: 600)
        #expect(SleepTimerMath.extended(duration, configuration: config) == .duration(deadline: now.addingTimeInterval(660), original: 600))
        var fixed = config
        fixed.extendByPrevious = false
        #expect(SleepTimerMath.extended(duration, configuration: fixed) == .duration(deadline: now.addingTimeInterval(1260), original: 600))
        #expect(SleepTimerMath.extended(.chapters(remaining: 1, original: 3), configuration: config) == .chapters(remaining: 4, original: 3))
        #expect(SleepTimerMath.extended(.chapters(remaining: 1, original: 3), configuration: fixed) == .chapters(remaining: 2, original: 3))
        #expect(SleepTimerMath.restarted(after: .duration(deadline: now, original: 300), configuration: config, now: now) == .duration(deadline: now.addingTimeInterval(300), original: 300))
    }

    @Test func adjust() {
        let state = SleepTimerState.duration(deadline: now.addingTimeInterval(90), original: 600)
        #expect(SleepTimerMath.adjusted(state, by: 1, now: now, pausedAt: nil) == .duration(deadline: now.addingTimeInterval(150), original: 600))
        #expect(SleepTimerMath.adjusted(state, by: -1, now: now, pausedAt: nil) == .duration(deadline: now.addingTimeInterval(30), original: 600))
        #expect(SleepTimerMath.adjusted(state, by: -2, now: now, pausedAt: nil) == nil)
        #expect(SleepTimerMath.adjusted(.chapters(remaining: 1, original: 1), by: -1, now: now, pausedAt: nil) == nil)
        #expect(SleepTimerMath.adjusted(.chapters(remaining: 1, original: 1), by: 1, now: now, pausedAt: nil) == .chapters(remaining: 2, original: 1))
    }

    @Test func fade() {
        #expect(SleepTimerMath.fadeVolume(timeRemaining: 20) == 1)
        #expect(SleepTimerMath.fadeVolume(timeRemaining: 5) == 0.5)
        #expect(SleepTimerMath.fadeVolume(timeRemaining: 0) == 0)
    }

    @Test func chapterTransitions() {
        let state = SleepTimerState.chapters(remaining: 2, original: 2)
        #expect(SleepTimerMath.chapterTransition(state, from: 3, to: 4) == .decremented(.chapters(remaining: 1, original: 2)))
        #expect(SleepTimerMath.chapterTransition(state, from: 3, to: 5) == .none)
        #expect(SleepTimerMath.chapterTransition(state, from: 4, to: 3) == .none)
        #expect(SleepTimerMath.chapterTransition(.chapters(remaining: 1, original: 1), from: 0, to: 1) == .expire)
        #expect(SleepTimerMath.chapterTransition(.duration(deadline: now, original: 1), from: 0, to: 1) == .none)
    }
}

@Suite struct SkipTapCombinerTests {
    @Test func combinesTaps() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var combiner = SkipTapCombiner()
        let first = combiner.registerTap(amount: 30, at: start)
        #expect(first == start.addingTimeInterval(0.3))
        #expect(combiner.flush(at: start.addingTimeInterval(0.1)) == nil)
        let second = combiner.registerTap(amount: 30, at: start.addingTimeInterval(0.2))
        #expect(abs(second.timeIntervalSince(start) - 0.9) < 1e-9)
        combiner.registerTap(amount: -15, at: start.addingTimeInterval(0.5))
        #expect(combiner.total == 45)
        #expect(combiner.tapCount == 3)
        #expect(combiner.flush(at: start.addingTimeInterval(2)) == 45)
        #expect(!combiner.isPending)
        combiner.registerTap(amount: 10, at: start.addingTimeInterval(5))
        #expect(combiner.total == 10)
    }
}

@Suite struct PlaybackRateMathTests {
    @Test func cyclesPresets() {
        let presets = [0.9, 1.0, 1.3, 1.6, 2.0]
        #expect(PlaybackRateMath.next(after: 1.0, presets: presets) == 1.3)
        #expect(PlaybackRateMath.next(after: 2.0, presets: presets) == 0.9)
        #expect(PlaybackRateMath.next(after: 1.15, presets: presets) == 1.3)
        #expect(PlaybackRateMath.next(after: 1, presets: []) == 1)
    }

    @Test func clamps() {
        #expect(PlaybackRateMath.clamp(10) == 4)
        #expect(PlaybackRateMath.clamp(0.1) == 0.25)
        #expect(PlaybackRateMath.clamp(1.2000001) == 1.2)
    }

    @Test func groupingPriority() {
        let book = ItemIdentifier(kind: .audiobook, connectionID: "c", libraryID: "l", primaryID: "b")
        let collection = ItemIdentifier(kind: .collection, connectionID: "c", libraryID: "l", primaryID: "col")
        let item = AnyPlayableItem.audiobook(Audiobook(id: book, name: "Book", series: [SeriesFragment(id: "s", name: "Series", sequence: "1")]))
        let candidates = PlaybackRateMath.groupingCandidates(for: item, origin: .collection(collection))
        #expect(candidates.map(\.primaryID) == ["col", "s"])
        #expect(candidates[1].kind == .series)

        let episodeID = ItemIdentifier(kind: .episode, connectionID: "c", libraryID: "l", primaryID: "e", groupingID: "p")
        let episode = AnyPlayableItem.episode(Episode(id: episodeID, name: "E", podcastName: "P"))
        #expect(PlaybackRateMath.groupingCandidates(for: episode, origin: .none).map(\.primaryID) == ["p"])
    }
}

@Suite struct QueueLogicTests {
    func item(_ id: String) -> AnyPlayableItem {
        .audiobook(Audiobook(id: ItemIdentifier(kind: .audiobook, connectionID: "c", libraryID: "l", primaryID: id), name: id))
    }

    @Test func moves() {
        #expect(QueueLogic.moved([1, 2, 3, 4], from: [0], to: 3) == [2, 3, 1, 4])
        #expect(QueueLogic.moved([1, 2, 3, 4], from: [3], to: 0) == [4, 1, 2, 3])
        #expect(QueueLogic.moved([1, 2, 3, 4], from: [0, 1], to: 4) == [3, 4, 1, 2])
        #expect(QueueLogic.removed([1, 2, 3], at: [1]) == [1, 3])
    }

    @Test func prunes() {
        let items = [item("a"), item("b"), item("a"), item("c"), item("d")]
        let pruned = QueueLogic.pruned(items, excluding: [item("d").id]) { $0.primaryID == "b" }
        #expect(pruned.map(\.id.primaryID) == ["a", "c"])
    }

    @Test func insertsAndTakes() {
        let queue = [item("a"), item("b")]
        #expect(QueueLogic.insertingFront(item("b"), into: queue).map(\.id.primaryID) == ["b", "a"])
        #expect(QueueLogic.appending(item("a"), to: queue).count == 2)
        let taken = QueueLogic.take(queue, at: 0)
        #expect(taken?.element.id.primaryID == "a")
        #expect(taken?.remaining.map(\.id.primaryID) == ["b"])
        #expect(QueueLogic.take(queue, at: 5) == nil)
    }
}

@Suite struct SmartRewindTests {
    @Test func rules() {
        #expect(SmartRewind.resumeRewind(pausedFor: 10) == 0)
        #expect(SmartRewind.resumeRewind(pausedFor: 31) == 10)
        #expect(SmartRewind.resumeRewind(pausedFor: 601) == 30)
        let now = Date()
        #expect(SmartRewind.coldStartRewind(lastUpdate: now.addingTimeInterval(-700), now: now) == 30)
        #expect(SmartRewind.coldStartRewind(lastUpdate: now.addingTimeInterval(-60), now: now) == 0)
        #expect(SmartRewind.coldStartRewind(lastUpdate: nil, now: now) == 0)
        #expect(SmartRewind.apply(10, to: 105, chapterStart: 100) == 100)
        #expect(SmartRewind.apply(30, to: 105, chapterStart: 100) == 75)
        #expect(SmartRewind.apply(10, to: 5, chapterStart: nil) == 0)
    }
}

@Suite struct DescriptionChapterParserTests {
    @Test func parsesTimestamps() {
        let html = "<p>Show notes</p><p>00:00 Intro<br>(05:30) Main topic<br/>1:02:03 - Outro &amp; credits</p><p>Talk at 12:00 about stuff</p>"
        let chapters = DescriptionChapterParser.chapters(from: html, duration: 4000)
        #expect(chapters.map(\.start) == [0, 330, 3723])
        #expect(chapters.map(\.title) == ["Intro", "Main topic", "Outro & credits"])
        #expect(chapters.map(\.end) == [330, 3723, 4000])
    }

    @Test func ignoresSingleOrInvalid() {
        #expect(DescriptionChapterParser.chapters(from: "10:00 Only one", duration: 1000).isEmpty)
        #expect(DescriptionChapterParser.chapters(from: "00:00 A\n99:99 B", duration: 1000).isEmpty)
        #expect(DescriptionChapterParser.chapters(from: nil, duration: 10).isEmpty)
        // Timestamps beyond the duration are dropped.
        #expect(DescriptionChapterParser.chapters(from: "00:00 A\n10:00 B\n50:00 C", duration: 1200).count == 2)
    }
}

@Suite struct AudioRouteClassifierTests {
    @Test func classifies() {
        #expect(AudioRouteClassifier.kind(port: .bluetoothA2DP, name: "Robin's AirPods Pro") == .airPodsPro)
        #expect(AudioRouteClassifier.kind(port: .bluetoothA2DP, name: "AirPods Max") == .airPodsMax)
        #expect(AudioRouteClassifier.kind(port: .bluetoothLE, name: "AirPods") == .airPods)
        #expect(AudioRouteClassifier.kind(port: .bluetoothA2DP, name: "Beats Studio") == .headphones)
        #expect(AudioRouteClassifier.kind(port: .bluetoothA2DP, name: "JBL Flip") == .bluetooth)
        #expect(AudioRouteClassifier.kind(port: .airPlay, name: "Kitchen HomePod mini") == .homePodMini)
        #expect(AudioRouteClassifier.kind(port: .airPlay, name: "Living Room Apple TV") == .appleTV)
        #expect(AudioRouteClassifier.kind(port: .airPlay, name: "Sonos") == .airPlay)
        #expect(AudioRouteClassifier.kind(port: .carAudio, name: "CarPlay") == .car)
        #expect(AudioRouteClassifier.route(port: .builtInSpeaker, name: "Speaker", deviceName: "iPhone") == AudioRoute(name: "iPhone", kind: .speaker))
    }
}

@Suite struct ListeningClockTests {
    @Test func accountsWallClock() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var clock = ListeningClock()
        #expect(!clock.isReportDue(at: start))
        clock.start(at: start)
        #expect(!clock.isReportDue(at: start.addingTimeInterval(2)))
        #expect(clock.isReportDue(at: start.addingTimeInterval(3)))
        #expect(clock.drain(at: start.addingTimeInterval(3)) == 3)
        #expect(!clock.isReportDue(at: start.addingTimeInterval(20)))
        #expect(clock.isReportDue(at: start.addingTimeInterval(33)))
        clock.stop(at: start.addingTimeInterval(13))
        #expect(clock.unreported(at: start.addingTimeInterval(100)) == 10)
        #expect(!clock.isReportDue(at: start.addingTimeInterval(100)))
        #expect(clock.drain(at: start.addingTimeInterval(100)) == 10)
        #expect(clock.unreported(at: start.addingTimeInterval(200)) == 0)
    }
}
