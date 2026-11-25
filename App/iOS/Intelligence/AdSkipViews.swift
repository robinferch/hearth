import HearthData
import HearthModel
import HearthPlayback
import HearthUI
import SwiftUI

/// "Ad skipped · Undo" after an automatic skip.
struct AdSkipToast: View {
    private var player: AudioPlayer { .shared }

    var body: some View {
        Group {
            if let skipped = player.lastSkippedAd {
                HStack(spacing: 12) {
                    Image(systemName: "forward.end.alt.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Ad skipped", tableName: "Intelligence")
                            .font(.subheadline.weight(.semibold))
                        Text(HearthFormat.joined([skipped.segment.advertiser, HearthFormat.duration(skipped.segment.duration)]))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await player.undoAdSkip() }
                    } label: {
                        Text("Undo", tableName: "Intelligence")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.glass)
                }
                .padding(.leading, 16)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .contain)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: player.lastSkippedAd)
        .sensoryFeedback(.impact(weight: .light), trigger: player.lastSkippedAd)
    }
}

/// Shown while an ad plays that isn't skipped automatically.
struct SkipAdButton: View {
    private var player: AudioPlayer { .shared }

    var body: some View {
        Group {
            if let ad = player.currentAd, player.lastSkippedAd == nil {
                Button {
                    Task { await player.skipCurrentAd() }
                } label: {
                    Label(String(localized: "Skip Ad · \(HearthFormat.duration(max(0, ad.end - player.currentTime)))", table: "Intelligence"), systemImage: "forward.end.alt.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.glass)
                .transition(.scale.combined(with: .opacity))
                .accessibilityIdentifier("player.skipAd")
            }
        }
        .animation(.smooth, value: player.currentAd)
    }
}

/// Ad ranges of the current item below the scrubber (in the scrubber's displayed range).
struct AdMarkersBar: View {
    private var player: AudioPlayer { .shared }

    var body: some View {
        let ads = player.currentAdSegments
        let total = player.displayedDuration
        let origin = player.currentTime - player.displayedTime
        if !ads.isEmpty, total > 0 {
            GeometryReader { proxy in
                ForEach(ads) { ad in
                    let start = max(0, (ad.start - origin) / total)
                    let end = min(1, (ad.end - origin) / total)
                    if end > start {
                        Capsule()
                            .fill(.orange)
                            .frame(width: max(3, (end - start) * proxy.size.width), height: 3)
                            .offset(x: start * proxy.size.width)
                    }
                }
            }
            .frame(height: 3)
            .accessibilityHidden(true)
        }
    }
}
