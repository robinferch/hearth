import HearthData
import HearthIntelligence
import HearthModel
import HearthPlayback
import HearthUI
import SwiftUI

/// Full transcript: paragraphs with timestamps, the spoken word highlighted and followed while the item plays, tap
/// to play from a paragraph, search, ad breaks marked, copy/share, ad detection again, delete.
struct TranscriptView: View {
    let itemID: ItemIdentifier
    let title: String

    @Environment(\.dismiss) private var dismiss
    @Environment(AlertCenter.self) private var alerts
    @State private var transcript: Transcript?
    @State private var isLoading = true
    @State private var query = ""
    @State private var matchIndex = 0
    @State private var isFollowing = true
    @State private var isConfirmingDelete = false
    @State private var adDetectionProgress: Double?

    private var player: AudioPlayer { .shared }
    private var isCurrent: Bool { player.isCurrent(itemID) }

    var body: some View {
        Group {
            if let transcript {
                content(transcript)
            } else if isLoading {
                ProgressView()
            } else {
                ContentUnavailableView(String(localized: "No Transcript", table: "Intelligence"), systemImage: "captions.bubble")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: String(localized: "Search Transcript", table: "Intelligence"))
        .onChange(of: query) { matchIndex = 0 }
        .toolbar { toolbar }
        .confirmationDialog(String(localized: "Delete this transcript?", table: "Intelligence"), isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button(String(localized: "Delete Transcript", table: "Intelligence"), role: .destructive) {
                HearthData.shared.transcripts.remove(itemID)
                dismiss()
            }
        } message: {
            Text("Detected ads are deleted as well.", tableName: "Intelligence")
        }
        .task(id: itemID) {
            transcript = await HearthData.shared.transcripts.transcript(for: itemID)
            isLoading = false
        }
    }

    // MARK: Content

    private func content(_ transcript: Transcript) -> some View {
        let layout = TranscriptLayout(transcript: transcript, ads: HearthData.shared.transcripts.adSegments(for: itemID))
        let matches = layout.matches(query)
        let position = isCurrent ? layout.position(at: player.currentTime) : nil
        let active = position?.paragraph
        let currentMatch = matches.isEmpty ? nil : matches[min(matchIndex, matches.count - 1)]
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    TranscriptHeader(transcript: transcript, ads: layout.ads, adDetectionProgress: adDetectionProgress)
                    ForEach(layout.paragraphs.indices, id: \.self) { index in
                        let ad = layout.ad(forParagraph: index)
                        if let ad, index == 0 || layout.ad(forParagraph: index - 1) != ad {
                            AdBanner(ad: ad)
                        }
                        TranscriptParagraph(
                            segments: transcript.segments[layout.paragraphs[index]],
                            firstIndex: layout.paragraphs[index].lowerBound,
                            position: index == active ? position : nil,
                            isDimmed: position != nil && index != active,
                            isAd: ad != nil,
                            query: query,
                            isCurrentMatch: index == currentMatch
                        ) {
                            play(from: transcript.segments[layout.paragraphs[index].lowerBound].start)
                        }
                        .id(index)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting {
                    isFollowing = false
                }
            }
            .onChange(of: active) { _, index in
                guard isFollowing, query.isEmpty, let index else { return }
                withAnimation(.smooth) { proxy.scrollTo(index, anchor: .center) }
            }
            .onChange(of: currentMatch) { _, index in
                guard let index else { return }
                withAnimation(.smooth) { proxy.scrollTo(index, anchor: .center) }
            }
            .onAppear {
                if let active {
                    proxy.scrollTo(active, anchor: .center)
                }
            }
            .safeAreaInset(edge: .bottom) {
                bottomBar(matches: matches, active: active, proxy: proxy)
            }
        }
    }

    @ViewBuilder
    private func bottomBar(matches: [Int], active: Int?, proxy: ScrollViewProxy) -> some View {
        if !query.isEmpty {
            HStack(spacing: 16) {
                Text(matches.isEmpty
                     ? String(localized: "No matches", table: "Intelligence")
                     : String(localized: "\(min(matchIndex, matches.count - 1) + 1) of \(matches.count)", table: "Intelligence"))
                    .font(.subheadline.monospacedDigit())
                Spacer()
                Button {
                    matchIndex = (matchIndex - 1 + matches.count) % max(matches.count, 1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .accessibilityLabel(String(localized: "Previous Match", table: "Intelligence"))
                Button {
                    matchIndex = (matchIndex + 1) % max(matches.count, 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .accessibilityLabel(String(localized: "Next Match", table: "Intelligence"))
            }
            .disabled(matches.isEmpty)
            .font(.headline)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        } else if !isFollowing, let active {
            Button {
                isFollowing = true
                withAnimation(.smooth) { proxy.scrollTo(active, anchor: .center) }
            } label: {
                Label(String(localized: "Follow Along", table: "Intelligence"), systemImage: "text.line.first.and.arrowtriangle.forward")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if let transcript {
                    Button {
                        UIPasteboard.general.string = transcript.plainText
                        alerts.succeed()
                    } label: {
                        Label(String(localized: "Copy Text", table: "Intelligence"), systemImage: "doc.on.doc")
                    }
                    ShareLink(item: transcript.plainText, subject: Text(title)) {
                        Label(String(localized: "Share Text", table: "Intelligence"), systemImage: "square.and.arrow.up")
                    }
                    Button {
                        detectAdsAgain()
                    } label: {
                        Label(String(localized: "Find Ads Again", table: "Intelligence"), systemImage: "sparkles")
                    }
                    .disabled(adDetectionProgress != nil)
                }
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label(String(localized: "Delete Transcript", table: "Intelligence"), systemImage: "trash")
                }
            } label: {
                Label(String(localized: "More", table: "Intelligence"), systemImage: "ellipsis")
            }
        }
    }

    // MARK: Actions

    private func play(from time: TimeInterval) {
        Task {
            do {
                if isCurrent {
                    await player.seek(to: time)
                    if !player.isPlaying {
                        player.resume()
                    }
                } else {
                    try await player.play(itemID, at: time)
                }
                isFollowing = true
            } catch {
                alerts.fail(error)
            }
        }
    }

    private func detectAdsAgain() {
        adDetectionProgress = 0
        Task {
            defer { adDetectionProgress = nil }
            do {
                try await TranscriptionService.shared.detectAds(for: itemID) { value in
                    Task { @MainActor in adDetectionProgress = value }
                }
                alerts.succeed()
            } catch {
                alerts.fail(error)
            }
        }
    }
}

// MARK: - Pieces

private struct TranscriptHeader: View {
    let transcript: Transcript
    let ads: [AdSegment]
    let adDetectionProgress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(HearthFormat.joined([
                TranscriptionService.displayName(of: Locale(identifier: transcript.localeIdentifier)),
                String(localized: "\(transcript.wordCount) words", table: "Intelligence"),
                transcript.createdAt.formatted(date: .abbreviated, time: .omitted),
            ]))
            .font(.caption.smallCaps())
            .foregroundStyle(.secondary)
            if let adDetectionProgress {
                ProgressView(value: adDetectionProgress) {
                    Text("Finding ads…", tableName: "Intelligence")
                        .font(.caption)
                }
                .tint(.orange)
            } else if !ads.isEmpty {
                Label(HearthFormat.joined([
                    String(localized: "\(ads.count) ad breaks", table: "Intelligence"),
                    HearthFormat.duration(ads.reduce(0) { $0 + $1.duration }),
                ]), systemImage: "forward.end.alt")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            if adDetectionProgress == nil, let analysis = HearthData.shared.transcripts.adAnalysis(for: transcript.itemID) {
                Text(AdDetectionText.method(of: analysis))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Tap a paragraph to listen from there.", tableName: "Intelligence")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.bottom, 4)
    }
}

private struct AdBanner: View {
    let ad: AdSegment

    var body: some View {
        Label {
            Text(HearthFormat.joined([
                String(localized: "Ad", table: "Intelligence"),
                ad.advertiser,
                HearthFormat.duration(ad.duration),
            ]))
        } icon: {
            Image(systemName: "megaphone.fill")
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(.orange)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.orange.opacity(0.14), in: .capsule)
    }
}

/// Paragraphs, ads and the playing position of a transcript.
struct TranscriptLayout {
    struct Position: Hashable {
        var paragraph: Int
        var segment: Int
        var word: Int?
    }

    let transcript: Transcript
    let ads: [AdSegment]
    /// Segment index ranges.
    let paragraphs: [Range<Int>]

    init(transcript: Transcript, ads: [AdSegment]) {
        self.transcript = transcript
        self.ads = ads
        paragraphs = transcript.paragraphs(breaks: ads.flatMap { [$0.start, $0.end] })
    }

    /// The ad a paragraph belongs to (paragraphs are split at ad borders).
    func ad(forParagraph index: Int) -> AdSegment? {
        let start = transcript.segments[paragraphs[index].lowerBound].start
        return ads.first { $0.start <= start + 0.5 && start < $0.end }
    }

    func position(at time: TimeInterval) -> Position? {
        guard let segment = transcript.segmentIndex(at: time), let paragraph = paragraphIndex(containing: segment) else { return nil }
        return Position(paragraph: paragraph, segment: segment, word: transcript.wordIndex(at: time, inSegment: segment))
    }

    /// Paragraphs containing `query`.
    func matches(_ query: String) -> [Int] {
        var result: [Int] = []
        for segment in transcript.search(query) {
            if let paragraph = paragraphIndex(containing: segment), result.last != paragraph {
                result.append(paragraph)
            }
        }
        return result
    }

    private func paragraphIndex(containing segment: Int) -> Int? {
        var low = 0
        var high = paragraphs.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if paragraphs[mid].contains(segment) { return mid }
            if paragraphs[mid].lowerBound > segment { high = mid - 1 } else { low = mid + 1 }
        }
        return nil
    }
}

/// One transcript paragraph: timestamp + text with the spoken word and search matches highlighted.
struct TranscriptParagraph: View {
    let segments: ArraySlice<TranscriptSegment>
    /// Index of the first segment in the transcript (`position` uses transcript indices).
    let firstIndex: Int
    /// The playing position, when it is in this paragraph.
    let position: TranscriptLayout.Position?
    /// Another paragraph is playing.
    let isDimmed: Bool
    let isAd: Bool
    var query: String = ""
    var isCurrentMatch = false
    var compact = false
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                if !compact, let first = segments.first {
                    Text(HearthFormat.clock(first.start))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(position != nil ? Color.accentColor : Color.secondary)
                }
                Text(attributedText)
                    .font(compact ? .body : .title3)
                    .lineSpacing(compact ? 2 : 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
            .padding(.leading, isAd ? 10 : 0)
            .overlay(alignment: .leading) {
                if isAd {
                    Capsule().fill(.orange.opacity(0.7)).frame(width: 3)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(String(localized: "Plays from here", table: "Intelligence"))
    }

    private var attributedText: AttributedString {
        var text = AttributedString()
        for (offset, segment) in segments.enumerated() {
            let index = firstIndex + offset
            let pieces = segment.words.isEmpty ? [segment.text] : segment.words.map(\.text)
            for (wordIndex, word) in pieces.enumerated() {
                var piece = AttributedString(text.characters.isEmpty ? word : " " + word)
                piece.foregroundColor = color(segment: index, word: segment.words.isEmpty ? nil : wordIndex)
                if let position, position.segment == index, position.word == wordIndex, !segment.words.isEmpty {
                    piece.backgroundColor = Color.accentColor.opacity(0.35)
                }
                text += piece
            }
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            var searchRange = text.startIndex ..< text.endIndex
            while let range = text[searchRange].range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) {
                text[range].backgroundColor = isCurrentMatch ? Color.yellow.opacity(0.75) : Color.yellow.opacity(0.35)
                text[range].foregroundColor = .primary
                searchRange = range.upperBound ..< text.endIndex
            }
        }
        return text
    }

    /// Spoken words are bright, upcoming ones dimmed, other paragraphs dimmed while something plays.
    private func color(segment: Int, word: Int?) -> Color {
        guard let position else {
            return isDimmed ? .secondary : .primary
        }
        if segment < position.segment { return .primary }
        if segment > position.segment { return .secondary }
        guard let word, let current = position.word else { return .primary }
        return word <= current ? .primary : .secondary
    }
}
