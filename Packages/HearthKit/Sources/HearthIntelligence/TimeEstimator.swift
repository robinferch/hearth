import Foundation

/// Duration estimate shown before a transcription starts.
public struct TranscriptionEstimate: Hashable, Sendable {
    public var transcription: TimeInterval
    /// `0` when ads aren't detected.
    public var adDetection: TimeInterval
    /// Bytes to download first, when the item isn't downloaded (`0` = unknown size).
    public var downloadBytes: Int64?
    /// The speech model for the language has to be downloaded once.
    public var needsLanguageDownload: Bool

    public init(transcription: TimeInterval, adDetection: TimeInterval, downloadBytes: Int64? = nil, needsLanguageDownload: Bool = false) {
        self.transcription = transcription
        self.adDetection = adDetection
        self.downloadBytes = downloadBytes
        self.needsLanguageDownload = needsLanguageDownload
    }

    /// Processing time on the device (downloads excluded).
    public var processing: TimeInterval { transcription + adDetection }
}

/// Estimates processing times from speeds measured on this device.
public struct TimeEstimator: Hashable, Sendable {
    /// Seconds of audio transcribed per second.
    public var transcriptionSpeed: Double
    /// Seconds the language model needs per ad detection window.
    public var secondsPerAdWindow: Double

    public static let defaultTranscriptionSpeed = 40.0
    public static let defaultSecondsPerAdWindow = 4.0
    /// Audio covered by one ad detection window (~150 spoken words per minute, ~4 500 characters per window).
    public static let audioPerAdWindow: TimeInterval = 5 * 60

    public init(transcriptionSpeed: Double = defaultTranscriptionSpeed, secondsPerAdWindow: Double = defaultSecondsPerAdWindow) {
        self.transcriptionSpeed = transcriptionSpeed
        self.secondsPerAdWindow = secondsPerAdWindow
    }

    public func estimate(duration: TimeInterval, detectAds: Bool, downloadBytes: Int64? = nil, needsLanguageDownload: Bool = false) -> TranscriptionEstimate {
        TranscriptionEstimate(
            transcription: max(5, duration / max(transcriptionSpeed, 0.1)),
            adDetection: detectAds ? Double(Self.adWindowCount(forDuration: duration)) * secondsPerAdWindow : 0,
            downloadBytes: downloadBytes,
            needsLanguageDownload: needsLanguageDownload
        )
    }

    public static func adWindowCount(forDuration duration: TimeInterval) -> Int {
        max(1, Int((duration / audioPerAdWindow).rounded(.up)))
    }

    /// Exponential moving average; the first measurement replaces the default completely.
    public static func blended(_ current: Double, with sample: Double, isFirst: Bool, weight: Double = 0.35) -> Double {
        guard sample.isFinite, sample > 0 else { return current }
        return isFirst ? sample : current * (1 - weight) + sample * weight
    }

    /// Remaining time while a run is in progress: from the rate measured so far once it's meaningful (`minimumElapsed`),
    /// otherwise from `fallbackRate` (units per second).
    public static func remaining(done: Double, total: Double, elapsed: TimeInterval, fallbackRate: Double, minimumElapsed: TimeInterval = 8) -> TimeInterval {
        let left = max(0, total - done)
        guard left > 0 else { return 0 }
        if elapsed >= minimumElapsed, done > 0 {
            return left / (done / elapsed)
        }
        return left / max(fallbackRate, 0.0001)
    }
}
