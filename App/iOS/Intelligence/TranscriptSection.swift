import HearthData
import HearthIntelligence
import HearthModel
import HearthUI
import SwiftUI

/// Detail page section: create a transcript, follow its progress, or open it.
struct TranscriptSection: View {
    let item: AnyPlayableItem

    @State private var isCreating = false
    @State private var isShowing = false

    private var store: TranscriptStore { HearthData.shared.transcripts }

    var body: some View {
        if TranscriptionAvailability.isSupported || store.hasTranscript(item.id) {
            Section {
                DetailSectionTitle(title: String(localized: "Transcript", table: "Intelligence"))
                    .detailPlainRow(insets: EdgeInsets(top: 18, leading: 20, bottom: 6, trailing: 20))
                row
                    .listRowBackground(Color.clear)
            }
            .sheet(isPresented: $isCreating) {
                TranscriptionSheet(item: item)
            }
            .sheet(isPresented: $isShowing) {
                NavigationStack {
                    TranscriptView(itemID: item.id, title: item.name)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(role: .close) { isShowing = false }
                            }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private var row: some View {
        let job = TranscriptionService.shared.job(for: item.id)
        if let job, job.phase.isRunning {
            Button {
                isCreating = true
            } label: {
                HStack(spacing: 14) {
                    ProgressRing(progress: job.overallProgress)
                        .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Creating transcript…", tableName: "Intelligence")
                            .font(.subheadline.weight(.semibold))
                        if let remaining = job.remaining, remaining > 0 {
                            Text(String(localized: "\(IntelligenceFormat.approximate(remaining)) left", table: "Intelligence"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        } else if let entry = store.entry(for: item.id) {
            Button {
                isShowing = true
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "text.alignleft")
                        .font(.title3)
                        .foregroundStyle(.purple)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show Transcript", tableName: "Intelligence")
                            .font(.subheadline.weight(.semibold))
                        Text(summary(entry))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("detail.showTranscript")
        } else {
            Button {
                if let job, !job.phase.isRunning {
                    TranscriptionService.shared.dismiss(item.id)
                }
                isCreating = true
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "captions.bubble")
                        .font(.title3)
                        .foregroundStyle(.purple)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Create Transcript", tableName: "Intelligence")
                            .font(.subheadline.weight(.semibold))
                        Text("On this device · read along and skip ads", tableName: "Intelligence")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("detail.createTranscript")
        }
    }

    private func summary(_ entry: TranscriptStore.Entry) -> String {
        let ads = store.adSegments(for: item.id).count
        return HearthFormat.joined([
            String(localized: "\(entry.wordCount) words", table: "Intelligence"),
            store.adAnalysis(for: item.id) == nil ? nil
                : ads == 0 ? String(localized: "No ads", table: "Intelligence")
                : String(localized: "\(ads) ad breaks", table: "Intelligence"),
        ])
    }
}

private struct ProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(.purple, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth, value: progress)
        }
    }
}
