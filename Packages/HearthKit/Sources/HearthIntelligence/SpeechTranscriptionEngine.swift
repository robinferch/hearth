import AVFoundation
import Foundation
import HearthModel
import os
import Speech

public enum TranscriptionError: Error, Sendable, Equatable {
    /// Speech transcription isn't available on this device.
    case unsupportedDevice
    /// No speech model for the language.
    case unsupportedLanguage(String)
    /// The audio file couldn't be read (format not supported).
    case unreadableAudio(String)
    case downloadFailed
    case noSpeech
}

extension TranscriptionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedDevice:
            String(localized: "This device doesn't support on-device transcription.", bundle: .module)
        case .unsupportedLanguage(let language):
            String(localized: "Transcription isn't available for \(language).", bundle: .module)
        case .unreadableAudio(let reason):
            String(localized: "The audio file couldn't be read: \(reason)", bundle: .module)
        case .downloadFailed:
            String(localized: "The episode couldn't be downloaded.", bundle: .module)
        case .noSpeech:
            String(localized: "No speech was recognized.", bundle: .module)
        }
    }
}

/// Transcribes local audio files with `SpeechAnalyzer` / `SpeechTranscriber`, including word timings.
public enum SpeechTranscriptionEngine {
    private static let logger = Logger(subsystem: "me.robinferch.hearth", category: "SpeechTranscription")

    public static var isAvailable: Bool {
        SpeechTranscriber.isAvailable
    }

    public static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    /// The supported locale closest to `locale`, if any.
    public static func supportedLocale(for locale: Locale) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }

    /// Whether the speech model for `locale` is already on the device.
    public static func isInstalled(_ locale: Locale) async -> Bool {
        await AssetInventory.status(forModules: [makeTranscriber(locale)]) == .installed
    }

    /// Downloads and installs the speech model for `locale` if needed. `progress` receives 0…1.
    public static func prepare(_ locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        let modules: [any SpeechModule] = [makeTranscriber(locale)]
        if await AssetInventory.status(forModules: modules) == .installed {
            progress(1)
            return
        }
        try await reserve(locale)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
            progress(1)
            return
        }
        let monitor = Task {
            while !Task.isCancelled {
                progress(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        defer { monitor.cancel() }
        try await request.downloadAndInstall()
        progress(1)
    }

    /// Keeps the locale's assets allocated; releases another reservation when the limit is reached.
    private static func reserve(_ locale: Locale) async throws {
        let reserved = await AssetInventory.reservedLocales
        if reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            return
        }
        if reserved.count >= AssetInventory.maximumReservedLocales, let oldest = reserved.first {
            await AssetInventory.release(reservedLocale: oldest)
        }
        try await AssetInventory.reserve(locale: locale)
    }

    /// Transcribes `tracks` (local files, in order) and returns the segments in absolute item time.
    ///
    /// - Parameter progress: seconds of audio processed so far (absolute item time).
    public static func transcribe(tracks: [AudioTrack], locale: Locale, progress: @escaping @Sendable (TimeInterval) -> Void) async throws -> [TranscriptSegment] {
        guard isAvailable else { throw TranscriptionError.unsupportedDevice }
        var segments: [TranscriptSegment] = []
        for track in tracks.sorted(by: { $0.offset < $1.offset }) {
            try Task.checkCancellation()
            segments += try await transcribe(track, locale: locale, progress: progress)
        }
        return segments
    }

    private static func transcribe(_ track: AudioTrack, locale: Locale, progress: @escaping @Sendable (TimeInterval) -> Void) async throws -> [TranscriptSegment] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: track.url)
        } catch {
            throw TranscriptionError.unreadableAudio(error.localizedDescription)
        }
        let transcriber = makeTranscriber(locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering))
        let results = transcriber.results
        let offset = track.offset

        let collector = Task {
            var segments: [TranscriptSegment] = []
            for try await result in results {
                if let segment = segment(from: result.text, range: result.range, offset: offset) {
                    segments += sentences(of: segment)
                }
                progress(offset + result.range.end.seconds)
            }
            return segments
        }

        return try await withTaskCancellationHandler {
            do {
                if let lastSample = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: lastSample)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } catch {
                collector.cancel()
                throw error
            }
            let segments = try await collector.value
            progress(offset + track.duration)
            return segments
        } onCancel: {
            collector.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    private static func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
    }

    /// Splits a recognition result into sentences. Results can span several sentences; ad boundaries, the language
    /// model's line numbers and tap-to-play need sentence precision.
    static func sentences(of segment: TranscriptSegment, minimumWords: Int = 3) -> [TranscriptSegment] {
        guard segment.words.count > minimumWords else { return [segment] }
        var result: [TranscriptSegment] = []
        var current: [TranscriptWord] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            result.append(TranscriptSegment(start: first.start, end: last.end, text: current.map(\.text).joined(separator: " "), words: current))
            current = []
        }
        for word in segment.words {
            current.append(word)
            let stripped = word.text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”“»«)]"))
            if current.count >= minimumWords, let last = stripped.last, ".!?…".contains(last) {
                flush()
            }
        }
        if current.count < minimumWords, !current.isEmpty, var previous = result.popLast() {
            // A short tail belongs to the previous sentence.
            previous.words += current
            current = previous.words
        }
        flush()
        if var last = result.last, segment.end > last.end {
            last.end = segment.end
            result[result.count - 1] = last
        }
        return result
    }

    /// Builds a segment from a result: tokens with a leading space start a new word, others (sub-word pieces,
    /// punctuation) extend the previous one.
    static func segment(from text: AttributedString, range: CMTimeRange, offset: TimeInterval) -> TranscriptSegment? {
        var words: [TranscriptWord] = []
        for run in text.runs {
            let raw = String(text[run.range].characters)
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            let timeRange = run.audioTimeRange
            let startsWord = raw.first?.isWhitespace == true || words.isEmpty
            let isPunctuation = token.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) }
            if !startsWord || isPunctuation, !words.isEmpty {
                words[words.count - 1].text += token
                if let timeRange, timeRange.end.seconds.isFinite, !isPunctuation {
                    words[words.count - 1].end = max(words[words.count - 1].end, offset + timeRange.end.seconds)
                }
                continue
            }
            let start = timeRange.map { offset + $0.start.seconds } ?? words.last?.end ?? (offset + range.start.seconds)
            let end = timeRange.map { offset + $0.end.seconds } ?? start
            words.append(TranscriptWord(text: token, start: start.isFinite ? start : offset, end: end.isFinite ? end : start))
        }
        let plain = words.isEmpty
            ? String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            : words.map(\.text).joined(separator: " ")
        guard !plain.isEmpty else { return nil }
        let start = words.first?.start ?? (offset + range.start.seconds)
        let end = max(words.last?.end ?? 0, offset + range.end.seconds)
        return TranscriptSegment(start: start, end: end.isFinite ? end : start, text: plain, words: words)
    }
}
