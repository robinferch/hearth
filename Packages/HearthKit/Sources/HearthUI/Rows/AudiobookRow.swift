import HearthData
import HearthModel
import SwiftUI

/// List row for an audiobook: 80 pt cover (tap plays), bold title, "authors • narrators" (or series),
/// and a small-caps info line "#seq • year • remaining • 🅴 🅰".
public struct AudiobookRow: View {
    public enum Secondary: Sendable {
        /// "Authors • Narrators"
        case authorsAndNarrators
        /// Series name (used on author pages).
        case series
    }

    let audiobook: Audiobook
    let secondary: Secondary
    let coverSize: CGFloat

    @Environment(\.itemActionHandler) private var handler

    public init(audiobook: Audiobook, secondary: Secondary = .authorsAndNarrators, coverSize: CGFloat = 80) {
        self.audiobook = audiobook
        self.secondary = secondary
        self.coverSize = coverSize
    }

    private var secondaryText: String? {
        switch secondary {
        case .authorsAndNarrators:
            let joined = HearthFormat.joined([audiobook.authorLine, audiobook.narrators.isEmpty ? nil : audiobook.narrators.formatted(.list(type: .and, width: .short))])
            return joined.isEmpty ? nil : joined
        case .series:
            return audiobook.series.first?.formatted ?? audiobook.authorLine
        }
    }

    public var body: some View {
        let status = ItemStatus.of(audiobook.id)
        HStack(spacing: 12) {
            Button {
                Task { await handler.play(audiobook.id) }
            } label: {
                ItemImage(id: audiobook.id, size: .small, cornerRadius: 8)
                    .frame(width: coverSize, height: coverSize)
                    .overlay(alignment: .bottom) {
                        if status.isInProgress {
                            ProgressCapsule(progress: status.fraction, height: 3)
                                .padding(.horizontal, 6)
                                .padding(.bottom, 5)
                        }
                    }
            }
            .buttonStyle(.plain)
            .disabled(!handler.canPlay)
            .accessibilityLabel(loc("Play"))

            VStack(alignment: .leading, spacing: 3) {
                Text(audiobook.name)
                    .font(.headline)
                    .lineLimit(2)
                if let secondaryText {
                    Text(secondaryText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                AudiobookInfoLine(audiobook: audiobook, status: status)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Audiobook: \(audiobook.name)", bundle: .module))
        .accessibilityValue(status.accessibilityValue)
    }
}

/// Small-caps info line: "#seq • year • Finished / 3h left / 5h • 🅴 🅰".
public struct AudiobookInfoLine: View {
    let audiobook: Audiobook
    let status: ItemStatus
    let showsSequence: Bool

    public init(audiobook: Audiobook, status: ItemStatus, showsSequence: Bool = true) {
        self.audiobook = audiobook
        self.status = status
        self.showsSequence = showsSequence
    }

    private var text: String {
        let progressText: String = if status.isFinished {
            HearthFormat.finished(status.progress?.finishedAt)
        } else if status.isInProgress {
            HearthFormat.remaining(status.remaining(duration: audiobook.duration), rate: ItemStatus.effectiveRate(for: audiobook.id))
        } else {
            HearthFormat.duration(audiobook.duration)
        }
        return HearthFormat.joined([
            showsSequence ? HearthFormat.sequence(audiobook.series.first?.sequence) : nil,
            HearthFormat.year(from: audiobook.released),
            progressText,
        ])
    }

    public var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .lineLimit(1)
            if audiobook.explicit {
                Image(systemName: "e.square")
                    .accessibilityLabel(loc("Explicit"))
            }
            if audiobook.abridged {
                Image(systemName: "a.square")
                    .accessibilityLabel(loc("Abridged"))
            }
            if status.isDownloaded {
                Image(systemName: "arrow.down.circle")
                    .accessibilityLabel(loc("Downloaded"))
            } else if status.isDownloading {
                DownloadProgressRing(progress: status.downloadProgress, lineWidth: 1.5)
                    .frame(width: 11, height: 11)
            }
        }
        .font(.caption.smallCaps())
        .foregroundStyle(.secondary)
    }
}

#if DEBUG
#Preview("Audiobook row") {
    List {
        AudiobookRow(audiobook: PreviewFixtures.audiobook)
        AudiobookRow(audiobook: PreviewFixtures.audiobook2, secondary: .series)
    }
}
#endif
