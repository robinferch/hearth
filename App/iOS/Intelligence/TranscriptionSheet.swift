import HearthData
import HearthIntelligence
import HearthModel
import HearthUI
import SwiftUI

/// Explains on-device transcription, estimates its duration, starts it and shows its progress. Ends with the
/// transcript.
struct TranscriptionSheet: View {
    let item: AnyPlayableItem

    @Environment(\.dismiss) private var dismiss
    @State private var path: [TranscriptRoute] = []

    private var service: TranscriptionService { .shared }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let job = service.job(for: item.id) {
                    TranscriptionProgressView(job: job, item: item, path: $path)
                } else if !TranscriptionAvailability.isSupported {
                    ContentUnavailableView {
                        Label(String(localized: "Not Available", table: "Intelligence"), systemImage: "waveform.slash")
                    } description: {
                        Text("This device doesn't support on-device transcription.", tableName: "Intelligence")
                    }
                } else {
                    TranscriptionSetupView(item: item)
                }
            }
            .navigationTitle(String(localized: "Transcript", table: "Intelligence"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
            .navigationDestination(for: TranscriptRoute.self) { route in
                TranscriptView(itemID: route.itemID, title: item.name)
            }
        }
    }
}

struct TranscriptRoute: Hashable {
    let itemID: ItemIdentifier
}

// MARK: - Setup

private struct TranscriptionSetupView: View {
    let item: AnyPlayableItem

    @State private var locales: [Locale] = []
    @State private var didLoadLocales = false
    @State private var locale: Locale?
    @State private var detectAds = AppSettings.shared.detectAdsAfterTranscription
    @State private var estimate: TranscriptionEstimate?

    private var service: TranscriptionService { .shared }
    private var isDownloaded: Bool { HearthData.shared.downloads.localPlayback(for: item.id) != nil }
    private var adMethod: AdAnalysis.Method { AdDetector.method(for: locale ?? .current) }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                steps
                options
                if let estimate {
                    EstimateCard(estimate: estimate)
                }
                startButton
                Label(String(localized: "Audio and transcript never leave this device.", table: "Intelligence"), systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .task {
            if !didLoadLocales {
                locales = await service.supportedLocales()
                locale = await service.suggestedLocale(for: item)
                didLoadLocales = true
            }
        }
        .task(id: EstimateKey(locale: locale?.identifier, detectAds: detectAds)) {
            guard let locale else { return }
            let value = await service.estimate(for: item, locale: locale, detectAds: detectAds)
            withAnimation(.smooth) { estimate = value }
        }
    }

    private struct EstimateKey: Hashable {
        var locale: String?
        var detectAds: Bool
    }

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 76, height: 76)
                Image(systemName: "captions.bubble.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, options: .repeating.speed(0.4))
            }
            .padding(.top, 12)
            Text("Create Transcript", tableName: "Intelligence")
                .font(.title2.weight(.bold))
            Text(item.name)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
    }

    private var steps: some View {
        VStack(spacing: 0) {
            StepRow(
                number: 1,
                systemImage: "arrow.down.circle.fill",
                color: .blue,
                title: String(localized: "Download", table: "Intelligence"),
                detail: isDownloaded
                    ? String(localized: "Already downloaded.", table: "Intelligence")
                    : String(localized: "The audio is downloaded first and stays available offline.", table: "Intelligence")
            )
            StepRow(
                number: 2,
                systemImage: "waveform",
                color: .purple,
                title: String(localized: "Speech Recognition on This Device", table: "Intelligence"),
                detail: String(localized: "Apple's speech recognition writes down every word with its exact time, so the transcript follows along while you listen.", table: "Intelligence")
            )
            StepRow(
                number: 3,
                systemImage: "sparkles",
                color: .orange,
                title: String(localized: "Find Ads", table: "Intelligence"),
                detail: adMethod == .languageModel
                    ? String(localized: "Apple Intelligence finds sponsor reads and commercials, so Hearth can skip them automatically.", table: "Intelligence")
                    : String(localized: "Ads are found by typical phrases like promo codes and sponsor mentions (Apple Intelligence isn't available).", table: "Intelligence"),
                isLast: true,
                isDimmed: !detectAds
            )
        }
        .padding(16)
        .background(.fill.quinary, in: .rect(cornerRadius: 20))
    }

    private var options: some View {
        VStack(spacing: 0) {
            HStack {
                Label(String(localized: "Language", table: "Intelligence"), systemImage: "globe")
                Spacer()
                if !didLoadLocales {
                    ProgressView()
                } else if locales.isEmpty {
                    Text("Not Available", tableName: "Intelligence")
                        .foregroundStyle(.secondary)
                } else {
                    Picker(String(localized: "Language", table: "Intelligence"), selection: $locale) {
                        ForEach(locales, id: \.identifier) { locale in
                            Text(TranscriptionService.displayName(of: locale)).tag(Optional(locale))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }
            .padding(.vertical, 10)
            Divider()
            Toggle(isOn: $detectAds) {
                Label(String(localized: "Find and Skip Ads", table: "Intelligence"), systemImage: "forward.end.alt")
            }
            .padding(.vertical, 10)
        }
        .padding(.horizontal, 16)
        .background(.fill.quinary, in: .rect(cornerRadius: 20))
    }

    private var startButton: some View {
        Button {
            guard let locale else { return }
            AppSettings.shared.detectAdsAfterTranscription = detectAds
            withAnimation(.smooth) {
                service.start(item, locale: locale, detectAds: detectAds)
            }
        } label: {
            Label(String(localized: "Start Transcription", table: "Intelligence"), systemImage: "play.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .disabled(locale == nil)
        .accessibilityIdentifier("transcription.start")
    }
}

private struct StepRow: View {
    let number: Int
    let systemImage: String
    let color: Color
    let title: String
    let detail: String
    var isLast = false
    var isDimmed = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(color.gradient, in: .circle)
                if !isLast {
                    Rectangle()
                        .fill(.quaternary)
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, 4)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, isLast ? 0 : 16)
            Spacer(minLength: 0)
        }
        .opacity(isDimmed ? 0.45 : 1)
        .accessibilityElement(children: .combine)
    }
}

private struct EstimateCard: View {
    let estimate: TranscriptionEstimate

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(String(localized: "Estimated Time", table: "Intelligence"), systemImage: "clock")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(IntelligenceFormat.approximate(estimate.processing))
                    .font(.title3.weight(.bold))
                    .contentTransition(.numericText())
            }
            VStack(spacing: 6) {
                row(String(localized: "Transcription", table: "Intelligence"), IntelligenceFormat.approximate(estimate.transcription))
                if estimate.adDetection > 0 {
                    row(String(localized: "Finding ads", table: "Intelligence"), IntelligenceFormat.approximate(estimate.adDetection))
                }
                if let bytes = estimate.downloadBytes {
                    row(String(localized: "Plus download", table: "Intelligence"), bytes > 0 ? HearthFormat.bytes(bytes) : String(localized: "Size unknown", table: "Intelligence"))
                }
                if estimate.needsLanguageDownload {
                    row(String(localized: "Plus speech model", table: "Intelligence"), String(localized: "One-time download", table: "Intelligence"))
                }
            }
            Text("Keeps running when you leave Hearth. Estimates get more accurate with every transcript.", tableName: "Intelligence")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.fill.quinary, in: .rect(cornerRadius: 20))
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }
}

// MARK: - Progress

private struct TranscriptionProgressView: View {
    let job: TranscriptionService.Job
    let item: AnyPlayableItem
    @Binding var path: [TranscriptRoute]

    private var service: TranscriptionService { .shared }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                ring
                    .padding(.top, 24)
                VStack(spacing: 0) {
                    ForEach(job.steps, id: \.self) { step in
                        JobStepRow(step: step, job: job)
                        if step != job.steps.last {
                            Divider().padding(.leading, 48)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.fill.quinary, in: .rect(cornerRadius: 20))
                actions
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .sensoryFeedback(.success, trigger: job.phase == .finished)
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 12)
            Circle()
                .trim(from: 0, to: job.overallProgress)
                .stroke(AngularGradient(colors: [.purple, .indigo, .purple], center: .center), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth, value: job.overallProgress)
            VStack(spacing: 4) {
                switch job.phase {
                case .finished:
                    Image(systemName: "checkmark")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                case .failed, .cancelled:
                    Image(systemName: job.phase == .cancelled ? "stop.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(job.phase == .cancelled ? Color.secondary : Color.orange)
                default:
                    Text(HearthFormat.percent(job.overallProgress))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    if let remaining = job.remaining, remaining > 0 {
                        Text(String(localized: "\(IntelligenceFormat.approximate(remaining)) left", table: "Intelligence"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(width: 180, height: 180)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var actions: some View {
        switch job.phase {
        case .finished:
            VStack(spacing: 12) {
                if let count = job.adCount {
                    Label(count == 0
                          ? String(localized: "No ads found.", table: "Intelligence")
                          : String(localized: "\(count) ad breaks found – they're skipped automatically.", table: "Intelligence"),
                          systemImage: count == 0 ? "checkmark.seal" : "forward.end.alt.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button {
                    path.append(TranscriptRoute(itemID: item.id))
                } label: {
                    Label(String(localized: "Show Transcript", table: "Intelligence"), systemImage: "text.alignleft")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
        case .failed(let message):
            VStack(spacing: 12) {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                retryButton
            }
        case .cancelled:
            retryButton
        default:
            Button(role: .destructive) {
                service.cancel(item.id)
            } label: {
                Text("Cancel", tableName: "Intelligence")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
    }

    private var retryButton: some View {
        Button {
            withAnimation(.smooth) { service.dismiss(item.id) }
        } label: {
            Label(String(localized: "Try Again", table: "Intelligence"), systemImage: "arrow.clockwise")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
    }
}

private struct JobStepRow: View {
    let step: TranscriptionService.Step
    let job: TranscriptionService.Job

    private enum State {
        case pending
        case active
        case done
        case failed
    }

    private var state: State {
        if job.phase == .finished { return .done }
        guard let current = job.currentStep else {
            return .failed
        }
        if step < current { return .done }
        return step == current && job.phase != .queued ? .active : .pending
    }

    var body: some View {
        HStack(spacing: 14) {
            Group {
                switch state {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .active:
                    ProgressView()
                case .pending:
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                case .failed:
                    Image(systemName: "minus.circle").foregroundStyle(.tertiary)
                }
            }
            .font(.title3)
            .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(state == .active ? .semibold : .regular))
                if state == .active {
                    ProgressView(value: job.stepProgress)
                        .tint(.purple)
                }
            }
            Spacer(minLength: 0)
            if state == .active, job.stepProgress > 0 {
                Text(HearthFormat.percent(job.stepProgress))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch step {
        case .download: String(localized: "Downloading", table: "Intelligence")
        case .model: String(localized: "Preparing speech model", table: "Intelligence")
        case .transcription: String(localized: "Transcribing", table: "Intelligence")
        case .ads: String(localized: "Finding ads", table: "Intelligence")
        }
    }
}

// MARK: - Formatting

enum IntelligenceFormat {
    /// "about 4 min" style durations for estimates.
    static func approximate(_ seconds: TimeInterval) -> String {
        guard seconds >= 45 else {
            return String(localized: "under a minute", table: "Intelligence")
        }
        let rounded = seconds < 3600 ? (seconds / 60).rounded() * 60 : (seconds / 300).rounded() * 300
        let text = Duration.seconds(rounded).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return String(localized: "about \(text)", table: "Intelligence")
    }
}

/// Whether the transcription UI is offered (DEBUG: also with `-HearthDebugSampleTranscript` in the simulator).
enum TranscriptionAvailability {
    @MainActor static var isSupported: Bool {
        #if DEBUG
        if DebugSupport.usesSampleTranscript { return true }
        #endif
        return TranscriptionService.isSupported
    }
}
