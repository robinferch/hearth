import Foundation
import HearthData
import HearthModel

/// An ad the player skipped automatically.
public struct SkippedAd: Hashable, Sendable {
    public let segment: AdSegment
    public let itemID: ItemIdentifier
    public let date: Date
}

extension AudioPlayer {
    /// Detected ads of the current item (empty without an ad analysis).
    public var currentAdSegments: [AdSegment] {
        guard let currentItem else { return [] }
        return HearthData.shared.transcripts.adSegments(for: currentItem.id)
    }

    /// The ad playing right now.
    public var currentAd: AdSegment? {
        AdSkipLogic.segment(at: currentTime, in: currentAdSegments)
    }

    /// Skips the ad playing right now (manual skip when automatic skipping is off).
    public func skipCurrentAd() async {
        guard let ad = currentAd else { return }
        resetHandledAdsIfNeeded()
        handledAds.insert(ad.start)
        await seekInternal(to: ad.end)
    }

    /// Goes back to the start of the ad that was just skipped and plays it.
    public func undoAdSkip() async {
        guard let skipped = lastSkippedAd, isCurrent(skipped.itemID) else { return }
        lastSkippedAd = nil
        skippedAdClearTask?.cancel()
        await seekInternal(to: skipped.segment.start)
    }

    /// Called on every tick: seeks past an ad that starts playing.
    func checkAdSkip() {
        guard AppSettings.shared.skipAdsAutomatically, intendsToPlay, busyCount == 0, let item = currentItem else { return }
        resetHandledAdsIfNeeded()
        guard let ad = AdSkipLogic.segmentToSkip(at: currentTime, in: currentAdSegments, handled: handledAds) else { return }
        handledAds.insert(ad.start)
        logger.info("Skipping ad \(ad.start, format: .fixed(precision: 0))–\(ad.end, format: .fixed(precision: 0)) s")
        lastSkippedAd = SkippedAd(segment: ad, itemID: item.id, date: .now)
        skippedAdClearTask?.cancel()
        skippedAdClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.lastSkippedAd = nil
        }
        Task { await seekInternal(to: ad.end) }
    }

    /// Seeking into an ad means the listener wants to hear it.
    func markAdHandled(at time: TimeInterval) {
        resetHandledAdsIfNeeded()
        if let ad = AdSkipLogic.segment(at: time, in: currentAdSegments) {
            handledAds.insert(ad.start)
        }
    }

    private func resetHandledAdsIfNeeded() {
        guard handledAdsItemID != currentItem?.id else { return }
        handledAdsItemID = currentItem?.id
        handledAds = []
    }
}
