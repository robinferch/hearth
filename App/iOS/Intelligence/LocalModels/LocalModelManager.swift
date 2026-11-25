import Foundation
import FoundationModels
import HearthIntelligence
import HearthModel
import HuggingFace
import MLX
import MLXFoundationModels
import MLXLLM
import MLXLMCommon
import Observation
import OSLog
import UIKit

/// Open models (Gemma) on the device for ad detection: download, status, deletion, and the runner that
/// `AdDetectionPlan` uses. MLX models plug into FoundationModels (`LanguageModelSession(model:)`) from iOS 27 on.
@MainActor
@Observable
final class LocalModelManager {
    static let shared = LocalModelManager()

    enum Status: Equatable {
        case notDownloaded
        case downloading(Double)
        case ready
        case failed(String)
    }

    private(set) var statuses: [String: Status] = [:]

    @ObservationIgnored private var downloads: [String: Task<Void, Never>] = [:]
    private nonisolated static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hearth", category: "LocalModels")

    private init() {}

    /// Open models need iOS 27 (FoundationModels hosting MLX models).
    var isSupported: Bool {
        if #available(iOS 27.0, *) { true } else { false }
    }

    /// Weights live here (not in Caches: iOS may purge those, and a model is several GB). Excluded from backups.
    nonisolated static let directory: URL = {
        let url = URL.applicationSupportDirectory.appending(path: "Models", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var excluded = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        return url
    }()

    /// Registers the runner factory for `AdDetectionPlan`. Call once at launch.
    func start() {
        guard #available(iOS 27.0, *) else { return }
        // MLX keeps freed buffers for reuse; on an iPhone they count against the app's memory limit.
        Memory.cacheLimit = 64 * 1024 * 1024
        LocalAdModels.runnerFactory = { model in
            guard Self.isDownloaded(model) else { return nil }
            return MLXAdModelRunner(model: model, languageModel: Self.languageModel(for: model, progress: nil))
        }
        refresh()
    }

    func status(of model: LocalAdModel) -> Status {
        statuses[model.id] ?? (Self.isDownloaded(model) ? .ready : .notDownloaded)
    }

    func refresh() {
        for model in LocalAdModel.all where downloads[model.id] == nil {
            if case .failed = statuses[model.id] { continue }
            statuses[model.id] = Self.isDownloaded(model) ? .ready : .notDownloaded
        }
    }

    // MARK: Download & delete

    /// Downloads the model (and loads it once to check it works), then frees its memory again.
    func download(_ model: LocalAdModel) {
        guard #available(iOS 27.0, *), downloads[model.id] == nil else { return }
        let id = model.id
        statuses[id] = .downloading(0)
        downloads[id] = Task { [weak self] in
            let languageModel = Self.languageModel(for: model) { fraction in
                Task { @MainActor in
                    LocalModelManager.shared.reportProgress(fraction, for: id)
                }
            }
            do {
                try await languageModel.preload()
                await languageModel.evict()
                Self.logger.notice("Downloaded \(model.name, privacy: .public)")
                self?.statuses[id] = .ready
            } catch {
                await languageModel.evict()
                if Task.isCancelled {
                    self?.statuses[id] = Self.isDownloaded(model) ? .ready : .notDownloaded
                } else {
                    Self.logger.error("Downloading \(model.name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    self?.statuses[id] = .failed(error.localizedDescription)
                }
            }
            self?.downloads[id] = nil
        }
    }

    private func reportProgress(_ fraction: Double, for id: String) {
        guard case .downloading = statuses[id] else { return }
        statuses[id] = .downloading(fraction)
    }

    func cancelDownload(_ model: LocalAdModel) {
        downloads[model.id]?.cancel()
        if #available(iOS 27.0, *) {
            // Cancels the load task the model's loader runs in.
            Task { await Self.languageModel(for: model, progress: nil).evict() }
        }
    }

    /// Deletes all downloaded models, including ones no longer offered.
    func deleteAll() {
        for model in LocalAdModel.all {
            cancelDownload(model)
            statuses[model.id] = .notDownloaded
        }
        try? FileManager.default.removeItem(at: Self.directory)
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
    }

    func delete(_ model: LocalAdModel) {
        cancelDownload(model)
        if let repo = Repo.ID(rawValue: model.repository) {
            try? FileManager.default.removeItem(at: Self.cache.repoDirectory(repo: repo, kind: .model))
        }
        statuses[model.id] = .notDownloaded
    }

    /// Bytes the model occupies on disk.
    func diskUsage(of model: LocalAdModel) async -> Int64 {
        guard let repo = Repo.ID(rawValue: model.repository) else { return 0 }
        let directory = Self.cache.repoDirectory(repo: repo, kind: .model)
        return await Task.detached(priority: .utility) {
            let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
            var total: Int64 = 0
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys)) else { return total }
            while let file = enumerator.nextObject() as? URL {
                guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
                total += Int64(values.totalFileAllocatedSize ?? 0)
            }
            return total
        }.value
    }

    // MARK: MLX

    nonisolated static var cache: HubCache { HubCache(cacheDirectory: directory) }

    nonisolated static func isDownloaded(_ model: LocalAdModel) -> Bool {
        FileManager.default.fileExists(atPath: weightsLocation(model.repository).appending(path: "config.json").path)
    }

    /// The snapshot directory of a repository in the cache.
    nonisolated static func weightsLocation(_ id: String) -> URL {
        let cache = cache
        guard let repo = Repo.ID(rawValue: id) else { return cache.cacheDirectory }
        if let commit = cache.resolveRevision(repo: repo, kind: .model, ref: "main"),
           let snapshot = try? cache.snapshotPath(repo: repo, kind: .model, commitHash: commit) {
            return snapshot
        }
        return cache.repoDirectory(repo: repo, kind: .model)
    }

    /// Registry configurations carry each model family's end-of-turn tokens.
    nonisolated static func configuration(for model: LocalAdModel) -> ModelConfiguration {
        switch model.id {
        case "gemma-4-e2b": LLMRegistry.gemma4_e2b_it_4bit
        case "gemma-4-e4b": LLMRegistry.gemma4_e4b_it_4bit
        default: ModelConfiguration(id: model.repository)
        }
    }

    /// Built in a nonisolated function: MLX calls the closures on its own threads.
    @available(iOS 27.0, *)
    nonisolated static func languageModel(for model: LocalAdModel, progress: (@Sendable (Double) -> Void)?) -> MLXLanguageModel {
        MLXLanguageModel(
            configuration: configuration(for: model),
            weightsLocation: { id in weightsLocation(id) },
            progress: LoadProgressHandlers(download: { value in progress?(value.fractionCompleted) }),
            load: { configuration, progress in
                try await loadModelContainer(
                    from: HubDownloader(HubClient(cache: cache)),
                    using: TransformersTokenizerLoader(),
                    configuration: configuration,
                    progress: progress
                )
            }
        )
    }
}

/// Finds ads with an MLX model through FoundationModels, answering in plain text.
///
/// iOS terminates apps that use the GPU in the background, so a request never runs while Hearth is in the background:
/// it is refused before it starts and cancelled when the app leaves the foreground (MLX stops at cancellation). The
/// detector then uses keywords for the rest of the episode.
@available(iOS 27.0, *)
struct MLXAdModelRunner: AdModelRunner {
    let model: LocalAdModel
    let languageModel: MLXLanguageModel

    var method: AdAnalysis.Method { .localModel }
    var modelName: String? { model.name }
    var windowCharacters: Int { model.windowCharacters }
    /// Reading a whole 90-minute episode takes an open model several minutes on an iPhone; the candidate passages
    /// (~12 %) take seconds.
    var readsCandidatesOnly: Bool { true }
    /// An episode's analysis must not take longer than a minute.
    var timeBudget: TimeInterval? { 60 }

    var extendsToCuePassages: Bool { true }

    /// Answers in plain text (`AdDetector.textInstructions`): small open models get guided generation wrong far more
    /// often than a simple "120-131 Brand" list.
    func findAds(instructions: String, transcript: String) async throws -> [AdBlockCandidate] {
        try await withThrowingTaskGroup(of: [AdBlockCandidate].self) { group in
            group.addTask {
                guard await Self.isInForeground() else { throw NotInForeground() }
                let session = LanguageModelSession(model: languageModel, instructions: AdDetector.textInstructions)
                let response = try await session.respond(to: transcript, options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 200))
                return AdDetector.parseTextAnswer(response.content)
            }
            group.addTask {
                for await _ in NotificationCenter.default.notifications(named: UIApplication.willResignActiveNotification) {
                    break
                }
                throw NotInForeground()
            }
            defer { group.cancelAll() }
            guard let blocks = try await group.next() else { throw NotInForeground() }
            return blocks
        }
    }

    struct NotInForeground: Error {}

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hearth", category: "LocalModels")

    @MainActor
    private static func isInForeground() -> Bool {
        UIApplication.shared.applicationState == .active
    }

    /// Frees the model's memory (several GB) once the episode is done.
    func finish() async {
        Self.logger.notice("\(model.name, privacy: .public) used up to \(Memory.peakMemory / 1_000_000) MB; \(os_proc_available_memory() / 1_000_000) MB left for the app")
        await languageModel.evict()
        // Return the weights' memory to the system now, not when MLX next needs a buffer: loading the model again for
        // the next episode would otherwise exceed the app's memory limit (iOS terminates the app).
        Memory.clearCache()
    }
}
