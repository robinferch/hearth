import Foundation
import os
import HearthData
import HearthModel

/// Who finds the ads in a transcript (setting `AppSettings.adDetectionProvider`).
public enum AdDetectionProvider: String, CaseIterable, Identifiable, Sendable {
    /// Apple Intelligence when available, otherwise keywords.
    case automatic
    case appleIntelligence
    /// An open model (Gemma) running on this device with MLX.
    case localModel
    /// Claude with the user's own Anthropic API key.
    case anthropic
    case keywords

    public var id: String { rawValue }

    /// On-device open models are hidden for now: Gemma 4 E2B needs ~3.6 GB, about all iOS lets Hearth use without the
    /// increased-memory-limit entitlement, so the option would always fall back to keywords.
    public static let offersLocalModels = false

    /// The options shown in the settings.
    public static var selectable: [AdDetectionProvider] {
        allCases.filter { $0 != .localModel || offersLocalModels }
    }

    /// The provider for a stored setting; hidden or unknown options mean `.automatic`.
    public init(setting: String) {
        let provider = AdDetectionProvider(rawValue: setting) ?? .automatic
        self = Self.selectable.contains(provider) ? provider : .automatic
    }
}

/// An open model that can run on the device to find ads.
public struct LocalAdModel: Identifiable, Hashable, Sendable {
    /// Stable id stored in the settings.
    public let id: String
    public let name: String
    /// Hugging Face repository with the MLX weights.
    public let repository: String
    public let downloadBytes: Int64
    /// Numbered transcript characters per request: about one candidate passage, which small models judge best.
    public let windowCharacters: Int
    /// Free memory the app needs to load and run the model (weights plus working memory, measured on an iPhone).
    public let memoryNeeded: UInt64
    public let isRecommended: Bool

    /// Measured on three hand-labelled German episodes (10 ad blocks, candidate passages, plain-text answers, Mac
    /// timings): Gemma 4 E2B found 8 blocks at 85 % precision in 10 s (a 92-minute episode took 6.7 s on an
    /// iPhone 17 Pro Max), Gemma 4 E4B 9 at 94 % in 24 s. LFM3 1.7B (8 blocks, 40 % precision), Llama 3.2 3B (4 blocks), Qwen 3.5 2B
    /// and Gemma 3 1B (far too slow or unusable output) were dropped.
    public static let all: [LocalAdModel] = [
        LocalAdModel(id: "gemma-4-e2b", name: "Gemma 4 E2B", repository: "mlx-community/gemma-4-e2b-it-4bit",
                     downloadBytes: 3_580_000_000, windowCharacters: 1_500, memoryNeeded: 3_600_000_000, isRecommended: true),
        LocalAdModel(id: "gemma-4-e4b", name: "Gemma 4 E4B", repository: "mlx-community/gemma-4-e4b-it-4bit",
                     downloadBytes: 5_180_000_000, windowCharacters: 1_500, memoryNeeded: 5_600_000_000, isRecommended: false),
    ]

    public static func model(id: String) -> LocalAdModel? {
        all.first { $0.id == id }
    }

    /// Whether iOS currently lets the app use enough memory for the model. iOS terminates an app that goes over its
    /// memory limit, which is far below the device's memory (about 3.5 GB on a 12 GB iPhone without the
    /// increased-memory-limit entitlement), so this checks what the process may still use.
    public var fitsDevice: Bool {
        Self.availableMemory >= memoryNeeded
    }

    /// Memory the app may still use before iOS terminates it.
    public static var availableMemory: UInt64 {
        #if os(iOS)
        UInt64(os_proc_available_memory())
        #else
        ProcessInfo.processInfo.physicalMemory
        #endif
    }
}

/// Hooks for on-device open models. The app provides them (MLX needs iOS 27 and the app's dependencies); without
/// them, `AdDetectionProvider.localModel` falls back to keywords.
@MainActor
public enum LocalAdModels {
    /// A runner for a downloaded model, or `nil` when it isn't downloaded. Must not start a download.
    public static var runnerFactory: ((LocalAdModel) -> (any AdModelRunner)?)?

    /// Whether this device and OS can run open models.
    public static var isSupported: Bool { runnerFactory != nil }
}

/// The ad detection to run for a transcript: the configured provider, or keywords when it can't be used right now.
public struct AdDetectionPlan: Sendable {
    public enum Unavailability: Hashable, Sendable {
        case appleIntelligence(LanguageModelStatus)
        /// Apple Intelligence doesn't support the transcript's language.
        case language
        case localModelsUnsupported
        case localModelNotDownloaded(String)
        case localModelTooLarge(String)
        case missingAPIKey
    }

    public let provider: AdDetectionProvider
    /// `nil` = keyword heuristics.
    public let runner: (any AdModelRunner)?
    /// Why the configured provider isn't used.
    public let unavailability: Unavailability?

    public var method: AdAnalysis.Method { runner?.method ?? .heuristic }
    public var modelName: String? { runner?.modelName }
    /// The transcript is sent to Anthropic.
    public var usesCloud: Bool { method == .anthropic }

    /// The plan for the current settings and a transcript in `locale`.
    @MainActor
    public static func current(for locale: Locale) -> AdDetectionPlan {
        let settings = AppSettings.shared
        let provider = AdDetectionProvider(setting: settings.adDetectionProvider)
        switch provider {
        case .keywords:
            return AdDetectionPlan(provider: provider, runner: nil, unavailability: nil)
        case .automatic, .appleIntelligence:
            #if canImport(FoundationModels)
            let status = LanguageModelStatus.current
            guard status == .available else {
                // Automatic quietly uses keywords where Apple Intelligence isn't available.
                return AdDetectionPlan(provider: provider, runner: nil, unavailability: provider == .automatic ? nil : .appleIntelligence(status))
            }
            guard LanguageModelStatus.supports(locale) else {
                return AdDetectionPlan(provider: provider, runner: nil, unavailability: provider == .automatic ? nil : .language)
            }
            return AdDetectionPlan(provider: provider, runner: SystemModelRunner(), unavailability: nil)
            #else
            return AdDetectionPlan(provider: provider, runner: nil, unavailability: .appleIntelligence(.unavailable))
            #endif
        case .localModel:
            let model = LocalAdModel.model(id: settings.localAdModelID) ?? LocalAdModel.all[0]
            guard let factory = LocalAdModels.runnerFactory else {
                return AdDetectionPlan(provider: provider, runner: nil, unavailability: .localModelsUnsupported)
            }
            guard model.fitsDevice else {
                return AdDetectionPlan(provider: provider, runner: nil, unavailability: .localModelTooLarge(model.name))
            }
            guard let runner = factory(model) else {
                return AdDetectionPlan(provider: provider, runner: nil, unavailability: .localModelNotDownloaded(model.name))
            }
            return AdDetectionPlan(provider: provider, runner: runner, unavailability: nil)
        case .anthropic:
            guard let key = SecretStore.value(.anthropicAPIKey) else {
                return AdDetectionPlan(provider: provider, runner: nil, unavailability: .missingAPIKey)
            }
            let model = AnthropicModel.model(id: settings.anthropicModel) ?? AnthropicModel.all[0]
            return AdDetectionPlan(provider: provider, runner: AnthropicAdModelRunner(apiKey: key, model: model), unavailability: nil)
        }
    }
}
