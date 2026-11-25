import Foundation
import HearthModel
import Testing
@testable import HearthPlayback

@Suite struct AdSkipLogicTests {
    let ads = [AdSegment(id: 0, start: 60, end: 120, confidence: 1), AdSegment(id: 1, start: 600, end: 630, confidence: 1)]

    @Test func skipsAnAdThatStartsPlaying() {
        #expect(AdSkipLogic.segmentToSkip(at: 59.9, in: ads, handled: []) == nil)
        #expect(AdSkipLogic.segmentToSkip(at: 60, in: ads, handled: [])?.end == 120)
        #expect(AdSkipLogic.segmentToSkip(at: 610, in: ads, handled: [])?.start == 600)
    }

    @Test func neverSkipsTheSameAdTwice() {
        #expect(AdSkipLogic.segmentToSkip(at: 70, in: ads, handled: [60]) == nil)
        #expect(AdSkipLogic.segmentToSkip(at: 610, in: ads, handled: [60])?.start == 600)
    }

    @Test func ignoresTheLastMomentsOfAnAd() {
        #expect(AdSkipLogic.segment(at: 119, in: ads) == nil)
        #expect(AdSkipLogic.segment(at: 118, in: ads)?.start == 60)
    }
}
