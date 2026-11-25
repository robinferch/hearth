import Foundation
import HearthData
import HearthModel
import Observation
import os

/// Runs transcription jobs (download → speech model → transcription → ad detection), one at a time, and publishes
/// their progress and remaining time.
@MainActor
@Observable
public final class TranscriptionService {
    public static let shared = TranscriptionService()

    public enum Phase: Hashable, Sendable {
        case queued
        case downloading(Double)
        case preparingModel(Double)
        case transcribing(Double)
        case detectingAds(Double)
        case finished
        case failed(String)
        case cancelled

        public var isRunning: Bool {
            switch self {
            case .queued, .downloading, .preparingModel, .transcribing, .detectingAds: true
            case .finished, .failed, .cancelled: false
            }
        }
    }

    public enum Step: Int, Hashable, Sendable, CaseIterable, Comparable {
        case download
        case model
        case transcription
        case ads

        public static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public struct Job: Identifiable, Hashable, Sendable {
        public let id: ItemIdentifier
        public var title: String
        public var duration: TimeInterval
        public var localeIdentifier: String
        public var detectAds: Bool
        public var phase: Phase
        public var createdAt: Date
        /// Estimated seconds until the job is done (`nil` while unknown, e.g. downloading).
        public var remaining: TimeInterval?
        /// Ads found (after the ad step).
        public var adCount: Int?
        /// Steps this job goes through (download / model only when needed).
        public var steps: [Step]

        public var currentStep: Step? {
            switch phase {
            case .queued: steps.first
            case .downloading: .download
            case .preparingModel: .model
            case .transcribing: .transcription
            case .detectingAds: .ads
            case .finished, .failed, .cancelled: nil
            }
        }

        /// Progress of the current step, 0…1.
        public var stepProgress: Double {
            switch phase {
            case .downloading(let value), .preparingModel(let value), .transcribing(let value), .detectingAds(let value): value
            case .finished: 1
            default: 0
            }
        }

        /// Overall progress weighted by the typical share of each step.
        public var overallProgress: Double {
            if phase == .finished { return 1 }
            guard let current = currentStep else { return 0 }
            let weights: [Step: Double] = [.download: 0.15, .model: 0.1, .transcription: 0.6, .ads: 0.15]
            let total = steps.reduce(0) { $0 + (weights[$1] ?? 0) }
            let done = steps.filter { $0 < current }.reduce(0) { $0 + (weights[$1] ?? 0) }
            return min(1, (done + (weights[current] ?? 0) * stepProgress) / max(total, 0.01))
        }
    }

    public private(set) var jobs: [ItemIdentifier: Job] = [:]
    /// Called when a job starts running (the app keeps it alive in the background).
    @ObservationIgnored public var jobStarted: (@MainActor (Job) -> Void)?

    @ObservationIgnored private var queue: [ItemIdentifier] = []
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var current: (id: ItemIdentifier, task: Task<Void, Never>)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let logger = Logger(subsystem: "me.robinferch.hearth", category: "TranscriptionService")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Capabilities

    public static var isSupported: Bool { SpeechTranscriptionEngine.isAvailable }

    public func job(for id: ItemIdentifier) -> Job? { jobs[id] }

    public var runningJobs: [Job] {
        jobs.values.filter(\.phase.isRunning).sorted { $0.createdAt < $1.createdAt }
    }

    /// Speeds measured on this device.
    public var estimator: TimeEstimator {
        TimeEstimator(
            transcriptionSpeed: defaults.object(forKey: Key.speed) as? Double ?? TimeEstimator.defaultTranscriptionSpeed,
            secondsPerAdWindow: defaults.object(forKey: Key.windowSeconds) as? Double ?? TimeEstimator.defaultSecondsPerAdWindow
        )
    }

    /// Supported languages, sorted by localized name.
    public func supportedLocales() async -> [Locale] {
        let locales = await SpeechTranscriptionEngine.supportedLocales()
        return locales.sorted { Self.displayName(of: $0) < Self.displayName(of: $1) }
    }

    /// The language to preselect: the podcast's or audiobook's language, else the app language.
    public func suggestedLocale(for item: AnyPlayableItem) async -> Locale? {
        var candidates: [Locale] = []
        switch item {
        case .audiobook(let book):
            if let language = book.language { candidates.append(Locale(identifier: Self.localeIdentifier(forLanguage: language))) }
        case .episode(let episode):
            if let podcastID = episode.id.podcastIdentifier,
               case .podcast(let podcast)? = try? await HearthData.shared.items.item(podcastID),
               let language = podcast.language {
                candidates.append(Locale(identifier: Self.localeIdentifier(forLanguage: language)))
            }
        }
        candidates.append(Locale.current)
        candidates.append(Locale(identifier: "en-US"))
        for candidate in candidates {
            if let supported = await SpeechTranscriptionEngine.supportedLocale(for: candidate) {
                return supported
            }
        }
        return nil
    }

    /// Feed languages come as codes (`de`, `en-us`) or names (`German`, `Deutsch`).
    nonisolated static func localeIdentifier(forLanguage language: String) -> String {
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = ["german": "de-DE", "deutsch": "de-DE", "english": "en-US", "englisch": "en-US", "french": "fr-FR",
                     "français": "fr-FR", "spanish": "es-ES", "español": "es-ES", "italian": "it-IT", "italiano": "it-IT"]
        return names[trimmed.lowercased()] ?? trimmed.replacingOccurrences(of: "_", with: "-")
    }

    public nonisolated static func displayName(of locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    // MARK: Estimate

    public func estimate(for item: AnyPlayableItem, locale: Locale, detectAds: Bool) async -> TranscriptionEstimate {
        let needsDownload = HearthData.shared.downloads.localPlayback(for: item.id) == nil
        let size: Int64? = switch item {
        case .audiobook(let book): book.size
        case .episode(let episode): episode.size
        }
        let installed = await SpeechTranscriptionEngine.isInstalled(locale)
        return estimator.estimate(
            duration: item.duration,
            detectAds: detectAds,
            downloadBytes: needsDownload ? (size ?? 0) : nil,
            needsLanguageDownload: !installed
        )
    }

    // MARK: Jobs

    public func start(_ item: AnyPlayableItem, locale: Locale, detectAds: Bool) {
        if let existing = jobs[item.id], existing.phase.isRunning { return }
        var steps: [Step] = []
        if HearthData.shared.downloads.localPlayback(for: item.id) == nil {
            steps.append(.download)
        }
        steps += [.model, .transcription]
        if detectAds {
            steps.append(.ads)
        }
        jobs[item.id] = Job(
            id: item.id,
            title: item.name,
            duration: item.duration,
            localeIdentifier: locale.identifier,
            detectAds: detectAds,
            phase: .queued,
            createdAt: .now,
            remaining: estimator.estimate(duration: item.duration, detectAds: detectAds).processing,
            steps: steps
        )
        queue.append(item.id)
        processQueue()
    }

    public func cancel(_ id: ItemIdentifier) {
        queue.removeAll { $0 == id }
        if current?.id == id {
            current?.task.cancel()
        } else if jobs[id]?.phase.isRunning == true {
            jobs[id]?.phase = .cancelled
        }
    }

    /// Removes a finished, failed or cancelled job from the list.
    public func dismiss(_ id: ItemIdentifier) {
        guard jobs[id]?.phase.isRunning == false else { return }
        jobs[id] = nil
    }

    /// Runs ad detection again on an existing transcript.
    @discardableResult
    public func detectAds(for id: ItemIdentifier, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> AdAnalysis {
        guard let transcript = await HearthData.shared.transcripts.transcript(for: id) else {
            throw TranscriptionError.noSpeech
        }
        let analysis = try await AdDetector().detect(in: transcript, progress: progress)
        HearthData.shared.transcripts.saveAds(analysis)
        return analysis
    }

    private func processQueue() {
        guard runner == nil else { return }
        runner = Task { [weak self] in
            while let self, let id = self.queue.first {
                self.queue.removeFirst()
                guard self.jobs[id]?.phase == .queued else { continue }
                let task = Task { await self.run(id) }
                self.current = (id, task)
                await task.value
                self.current = nil
            }
            self?.runner = nil
        }
    }

    // MARK: Running a job

    private func run(_ id: ItemIdentifier) async {
        guard let job = jobs[id] else { return }
        jobStarted?(job)
        let locale = Locale(identifier: job.localeIdentifier)
        do {
            let tracks = try await ensureDownloaded(id)
            try Task.checkCancellation()

            update(id) { $0.phase = .preparingModel(0); $0.remaining = nil }
            guard await SpeechTranscriptionEngine.supportedLocale(for: locale) != nil else {
                throw TranscriptionError.unsupportedLanguage(Self.displayName(of: locale))
            }
            try await SpeechTranscriptionEngine.prepare(locale) { [weak self] value in
                Task { @MainActor [weak self] in
                    self?.update(id) { if case .preparingModel = $0.phase { $0.phase = .preparingModel(value) } }
                }
            }
            try Task.checkCancellation()

            let transcript = try await transcribe(id, tracks: tracks, locale: locale)
            try await HearthData.shared.transcripts.save(transcript)

            if job.detectAds {
                try await detectAds(id, transcript: transcript)
            }
            update(id) { $0.phase = .finished; $0.remaining = 0 }
            logger.info("Transcribed \(id, privacy: .public): \(transcript.segments.count) segments")
        } catch is CancellationError {
            update(id) { $0.phase = .cancelled; $0.remaining = nil }
        } catch {
            logger.error("Transcribing \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            update(id) { $0.phase = Task.isCancelled ? .cancelled : .failed(error.localizedDescription); $0.remaining = nil }
        }
    }

    /// Downloads the item if needed (regular download manager) and returns its local tracks.
    private func ensureDownloaded(_ id: ItemIdentifier) async throws -> [AudioTrack] {
        let downloads = HearthData.shared.downloads
        if let local = downloads.localPlayback(for: id) {
            return local.tracks
        }
        update(id) { $0.phase = .downloading(0) }
        if downloads.status(of: id) == .none {
            try await downloads.download(id)
        }
        while true {
            try Task.checkCancellation()
            if let local = downloads.localPlayback(for: id) {
                return local.tracks
            }
            guard downloads.status(of: id) == .downloading else {
                throw TranscriptionError.downloadFailed
            }
            let progress = downloads.progress(of: id)
            update(id) { $0.phase = .downloading(progress) }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    private func transcribe(_ id: ItemIdentifier, tracks: [AudioTrack], locale: Locale) async throws -> Transcript {
        let total = max(tracks.map(\.end).max() ?? 0, jobs[id]?.duration ?? 0, 1)
        let fallbackSpeed = estimator.transcriptionSpeed
        let started = Date.now
        update(id) { $0.phase = .transcribing(0); $0.remaining = total / fallbackSpeed }

        let segments = try await SpeechTranscriptionEngine.transcribe(tracks: tracks, locale: locale) { [weak self] processed in
            Task { @MainActor [weak self] in
                let elapsed = Date.now.timeIntervalSince(started)
                self?.update(id) { job in
                    guard case .transcribing = job.phase else { return }
                    job.phase = .transcribing(min(1, processed / total))
                    let adTime = job.detectAds ? Double(TimeEstimator.adWindowCount(forDuration: total)) * (self?.estimator.secondsPerAdWindow ?? 4) : 0
                    job.remaining = TimeEstimator.remaining(done: processed, total: total, elapsed: elapsed, fallbackRate: fallbackSpeed) + adTime
                }
            }
        }
        guard !segments.isEmpty else { throw TranscriptionError.noSpeech }

        let elapsed = Date.now.timeIntervalSince(started)
        if elapsed > 5 {
            record(Key.speed, sample: total / elapsed, current: fallbackSpeed)
        }
        return Transcript(itemID: id, localeIdentifier: locale.identifier(.bcp47), duration: total, segments: segments)
    }

    private func detectAds(_ id: ItemIdentifier, transcript: Transcript) async throws {
        let windows = Double(TimeEstimator.adWindowCount(forDuration: transcript.duration))
        let perWindow = estimator.secondsPerAdWindow
        let started = Date.now
        update(id) { $0.phase = .detectingAds(0); $0.remaining = windows * perWindow }
        let analysis = try await AdDetector().detect(in: transcript) { [weak self] value in
            Task { @MainActor [weak self] in
                let elapsed = Date.now.timeIntervalSince(started)
                self?.update(id) { job in
                    guard case .detectingAds = job.phase else { return }
                    job.phase = .detectingAds(value)
                    job.remaining = TimeEstimator.remaining(done: value, total: 1, elapsed: elapsed, fallbackRate: 1 / max(windows * perWindow, 1), minimumElapsed: 4)
                }
            }
        }
        HearthData.shared.transcripts.saveAds(analysis)
        update(id) { $0.adCount = analysis.segments.count }
        let elapsed = Date.now.timeIntervalSince(started)
        if analysis.method == .languageModel, elapsed > 2 {
            let actualWindows = Double(AdDetector.windows(for: transcript.segments, characters: AdDetector().windowCharacters, overlap: AdDetector().overlapLines).count)
            record(Key.windowSeconds, sample: elapsed / max(actualWindows, 1), current: perWindow)
        }
    }

    private func update(_ id: ItemIdentifier, _ change: (inout Job) -> Void) {
        guard var job = jobs[id] else { return }
        change(&job)
        jobs[id] = job
    }

    private func record(_ key: String, sample: Double, current: Double) {
        let isFirst = defaults.object(forKey: key) == nil
        defaults.set(TimeEstimator.blended(current, with: sample, isFirst: isFirst), forKey: key)
    }

    private enum Key {
        static let speed = "intelligence.transcriptionSpeed"
        static let windowSeconds = "intelligence.secondsPerAdWindow"
    }
}
