import Foundation
import HearthModel
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Detects ads in a transcript: with Apple Intelligence when available, otherwise (and for windows the model
/// couldn't process) with keyword heuristics.
public struct AdDetector: Sendable {
    /// Characters of numbered transcript lines per model request (~1 300 tokens, leaving room for instructions,
    /// schema and answer within the 4 096 token context).
    public var windowCharacters = 4_500
    /// Lines repeated at the start of the next window, so blocks crossing a border are seen whole.
    public var overlapLines = 2

    private static let logger = Logger(subsystem: "me.robinferch.hearth", category: "AdDetector")

    public init() {}

    /// Which method `detect` will use for transcripts in `locale`.
    public static func method(for locale: Locale) -> AdAnalysis.Method {
        LanguageModelStatus.current == .available && LanguageModelStatus.supports(locale) ? .languageModel : .heuristic
    }

    /// - Parameter progress: called with values 0…1.
    public func detect(in transcript: HearthModel.Transcript, progress: @Sendable (Double) -> Void = { _ in }) async throws -> AdAnalysis {
        let locale = Locale(identifier: transcript.localeIdentifier)
        guard Self.method(for: locale) == .languageModel else {
            progress(1)
            return AdAnalysis(itemID: transcript.itemID, method: .heuristic, segments: HeuristicAdDetector().detect(in: transcript.segments))
        }
        #if canImport(FoundationModels)
        let windows = Self.windows(for: transcript.segments, characters: windowCharacters, overlap: overlapLines)
        var found: [AdSegment] = []
        for (index, window) in windows.enumerated() {
            try Task.checkCancellation()
            do {
                found += try await Self.detectWithModel(window, segments: transcript.segments)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Self.logger.notice("Window \(index) fell back to heuristics: \(String(describing: error), privacy: .public)")
                found += HeuristicAdDetector().detect(in: Array(transcript.segments[window]))
            }
            progress(Double(index + 1) / Double(windows.count))
        }
        return AdAnalysis(itemID: transcript.itemID, method: .languageModel, segments: AdAnalysis.normalized(found, joinGap: 8))
        #else
        return AdAnalysis(itemID: transcript.itemID, method: .heuristic, segments: HeuristicAdDetector().detect(in: transcript.segments))
        #endif
    }

    /// Ranges of segment indices, each fitting `characters` when rendered as numbered lines.
    static func windows(for segments: [TranscriptSegment], characters: Int, overlap: Int) -> [Range<Int>] {
        guard !segments.isEmpty else { return [] }
        var windows: [Range<Int>] = []
        var start = 0
        while start < segments.count {
            var end = start
            var used = 0
            while end < segments.count {
                let length = line(end, segments[end]).count + 1
                if used + length > characters, end > start { break }
                used += length
                end += 1
            }
            windows.append(start ..< end)
            guard end < segments.count else { break }
            start = max(start + 1, end - overlap)
        }
        return windows
    }

    static func line(_ index: Int, _ segment: TranscriptSegment) -> String {
        // Very long segments are cut; the start of a sentence is what identifies an ad.
        "[\(index)] \(segment.text.prefix(600))"
    }

    /// Converts the model's line ranges into time ranges, dropping implausible blocks.
    static func adSegments(from blocks: [(first: Int, last: Int, advertiser: String?)], window: Range<Int>, segments: [TranscriptSegment]) -> [AdSegment] {
        blocks.compactMap { block in
            let first = min(max(block.first, window.lowerBound), window.upperBound - 1)
            let last = min(max(block.last, first), window.upperBound - 1)
            let start = segments[first].start
            let end = segments[last].end
            guard end - start >= 8, end - start <= 6 * 60 else { return nil }
            let advertiser = block.advertiser?.trimmingCharacters(in: .whitespacesAndNewlines)
            return AdSegment(id: 0, start: start, end: end, advertiser: advertiser?.isEmpty == false ? advertiser : nil, confidence: 0.9)
        }
    }

    #if canImport(FoundationModels)
    @Generable
    struct AdWindowResult {
        @Guide(description: "The advertising blocks in the transcript lines. An empty list if there is no advertising.")
        var ads: [AdBlock]
    }

    @Generable
    struct AdBlock {
        @Guide(description: "Number of the first line of the advertising block")
        var firstLine: Int
        @Guide(description: "Number of the last line of the advertising block")
        var lastLine: Int
        @Guide(description: "The advertised brand, product or service, if named")
        var advertiser: String?
    }

    private static let instructions = """
        You find advertising in podcast transcripts. Advertising means: sponsor messages, ads read by the hosts, \
        inserted commercials, promo or discount codes, paid product placements and promotion of other podcasts. \
        Not advertising: normal conversation, the show's own intro or outro, and asking listeners to rate, follow or \
        support this show. The transcript may be in any language. Its lines are numbered like [12]. Answer with the \
        line ranges of the advertising blocks, or an empty list if there is none.
        """

    private static func detectWithModel(_ window: Range<Int>, segments: [TranscriptSegment]) async throws -> [AdSegment] {
        let lines = window.map { line($0, segments[$0]) }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: "Transcript lines \(window.lowerBound) to \(window.upperBound - 1):\n\(lines)",
            generating: AdWindowResult.self
        )
        return adSegments(from: response.content.ads.map { ($0.firstLine, $0.lastLine, $0.advertiser) }, window: window, segments: segments)
    }
    #endif
}

/// Availability of Apple Intelligence's on-device model.
public enum LanguageModelStatus: Hashable, Sendable {
    case available
    case deviceNotEligible
    case notEnabled
    case modelNotReady
    case unavailable

    public static var current: LanguageModelStatus {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .notEnabled
        case .unavailable(.modelNotReady): return .modelNotReady
        case .unavailable: return .unavailable
        }
        #else
        return .unavailable
        #endif
    }

    static func supports(_ locale: Locale) -> Bool {
        #if canImport(FoundationModels)
        return SystemLanguageModel.default.supportsLocale(locale)
        #else
        return false
        #endif
    }
}
