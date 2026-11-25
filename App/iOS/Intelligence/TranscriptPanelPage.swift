import HearthData
import HearthIntelligence
import HearthModel
import HearthPlayback
import HearthUI
import SwiftUI

/// Player panel page: the live transcript of the current item (follows playback, tap to jump), or a prompt to
/// create one.
struct TranscriptPanelPage: View {
    @State private var transcript: Transcript?
    @State private var isCreating = false
    @State private var isShowingFull = false
    @State private var isFollowing = true

    private var player: AudioPlayer { .shared }
    private var item: AnyPlayableItem? { player.currentItem }

    var body: some View {
        Group {
            if let item {
                if let transcript, transcript.itemID == item.id {
                    live(transcript, item: item)
                } else {
                    prompt(item)
                }
            }
        }
        .task(id: TaskKey(id: item?.id, hasTranscript: item.map { HearthData.shared.transcripts.hasTranscript($0.id) } ?? false)) {
            guard let item else { transcript = nil; return }
            transcript = await HearthData.shared.transcripts.transcript(for: item.id)
        }
        #if DEBUG
        .onAppear {
            // `-HearthDebugTranscriptionSheet YES` opens the transcription sheet (screenshots).
            if UserDefaults.standard.bool(forKey: "HearthDebugTranscriptionSheet") {
                isCreating = true
            }
        }
        #endif
        // The player forces a dark appearance with a white tint; its sheets follow with a dark background.
        .sheet(isPresented: $isCreating) {
            if let item {
                TranscriptionSheet(item: item)
                    .playerSheetStyle()
            }
        }
        .sheet(isPresented: $isShowingFull) {
            if let item {
                NavigationStack {
                    TranscriptView(itemID: item.id, title: item.name)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(role: .close) { isShowingFull = false }
                            }
                        }
                }
                .playerSheetStyle()
            }
        }
    }

    private struct TaskKey: Hashable {
        var id: ItemIdentifier?
        var hasTranscript: Bool
    }

    private func live(_ transcript: Transcript, item: AnyPlayableItem) -> some View {
        let layout = TranscriptLayout(transcript: transcript, ads: HearthData.shared.transcripts.adSegments(for: item.id))
        let position = layout.position(at: player.currentTime)
        let active = position?.paragraph
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(layout.paragraphs.indices, id: \.self) { index in
                        TranscriptParagraph(
                            segments: transcript.segments[layout.paragraphs[index]],
                            firstIndex: layout.paragraphs[index].lowerBound,
                            position: index == active ? position : nil,
                            isDimmed: position != nil && index != active,
                            isAd: layout.ad(forParagraph: index) != nil,
                            compact: true
                        ) {
                            isFollowing = true
                            Task { await player.seek(to: transcript.segments[layout.paragraphs[index].lowerBound].start) }
                        }
                        .id(index)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
            .mask {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06), .init(color: .black, location: 0.92), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting {
                    isFollowing = false
                }
            }
            .onAppear {
                if let active { proxy.scrollTo(active, anchor: .center) }
            }
            .onChange(of: active) { _, index in
                guard isFollowing, let index else { return }
                withAnimation(.smooth) { proxy.scrollTo(index, anchor: .center) }
            }
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 10) {
                    if !isFollowing, let active {
                        Button {
                            isFollowing = true
                            withAnimation(.smooth) { proxy.scrollTo(active, anchor: .center) }
                        } label: {
                            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                                .frame(width: 36, height: 36)
                        }
                        .accessibilityLabel(String(localized: "Follow Along", table: "Intelligence"))
                    }
                    Button {
                        isShowingFull = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .frame(width: 36, height: 36)
                    }
                    .accessibilityLabel(String(localized: "Full Transcript", table: "Intelligence"))
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .padding(8)
            }
        }
    }

    @ViewBuilder
    private func prompt(_ item: AnyPlayableItem) -> some View {
        let job = TranscriptionService.shared.job(for: item.id)
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: "captions.bubble")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            if let job, job.phase.isRunning {
                Text("Creating transcript…", tableName: "Intelligence")
                    .font(.headline)
                ProgressView(value: job.overallProgress)
                    .frame(maxWidth: 220)
                if let remaining = job.remaining, remaining > 0 {
                    Text(String(localized: "\(IntelligenceFormat.approximate(remaining)) left", table: "Intelligence"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if TranscriptionAvailability.isSupported {
                Text("No Transcript Yet", tableName: "Intelligence")
                    .font(.headline)
                Text("Create a transcript on this device to read along and skip ads.", tableName: "Intelligence")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("This device doesn't support on-device transcription.", tableName: "Intelligence")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if TranscriptionAvailability.isSupported {
                Button {
                    isCreating = true
                } label: {
                    Label(job?.phase.isRunning == true
                          ? String(localized: "Show Progress", table: "Intelligence")
                          : String(localized: "Create Transcript", table: "Intelligence"),
                          systemImage: job?.phase.isRunning == true ? "chart.bar.fill" : "captions.bubble")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("player.createTranscript")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    /// Sheets presented from the (always dark) player: dark background and the app's accent instead of the player's
    /// white tint, so text and prominent buttons stay readable.
    func playerSheetStyle() -> some View {
        self
            .tint(Color.accentColor)
            .environment(\.colorScheme, .dark)
            .presentationBackground(Color(white: 0.1))
    }
}
