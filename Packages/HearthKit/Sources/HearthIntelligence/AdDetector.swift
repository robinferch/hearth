import Foundation
import HearthData
import HearthModel
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

/// A language model that finds ad blocks in numbered transcript lines (Apple Intelligence, an open model on the
/// device, or Claude).
public protocol AdModelRunner: Sendable {
    var method: AdAnalysis.Method { get }
    /// Display name of the model (`nil` for Apple Intelligence).
    var modelName: String? { get }
    /// Characters of numbered transcript lines per request.
    var windowCharacters: Int { get }
    /// - Parameter transcript: numbered lines like `[12] Text`.
    func findAds(instructions: String, transcript: String) async throws -> [AdBlockCandidate]
    /// Called after the last request, e.g. to free a local model's memory.
    func finish() async
    /// Read only the candidate passages (`CandidateSelector`) instead of the whole transcript (slow models).
    var readsCandidatesOnly: Bool { get }
    /// Seconds after which the running request is cancelled and the remaining passages use the keyword heuristics
    /// (`nil` = no limit).
    var timeBudget: TimeInterval? { get }
    /// Small on-device models mark only the core of an ad: widen each block to the sponsor cues around it
    /// (`CandidateSelector`).
    var extendsToCuePassages: Bool { get }
}

public extension AdModelRunner {
    func finish() async {}
    var readsCandidatesOnly: Bool { false }
    var timeBudget: TimeInterval? { nil }
    var extendsToCuePassages: Bool { false }
}

/// An ad block as a model reports it: a range of transcript line numbers.
public struct AdBlockCandidate: Hashable, Codable, Sendable {
    public var firstLine: Int
    public var lastLine: Int
    public var advertiser: String?

    public init(firstLine: Int, lastLine: Int, advertiser: String? = nil) {
        self.firstLine = firstLine
        self.lastLine = lastLine
        self.advertiser = advertiser
    }
}

/// Detects ads in a transcript with a language model (see `AdDetectionPlan`), or with keyword heuristics. Windows the
/// model can't process fall back to the heuristics.
public struct AdDetector: Sendable {
    /// Lines repeated at the start of the next window, so blocks crossing a border are seen whole.
    public var overlapLines = 2

    private static let logger = Logger(subsystem: "me.robinferch.hearth", category: "AdDetector")

    public init() {}

    public static let instructions = """
        You find advertising in podcast transcripts. Advertising means: sponsor messages, ads read by the hosts, \
        inserted commercials, promo or discount codes, paid product placements and promotion of other podcasts. \
        Not advertising: normal conversation, the show's own intro or outro, and asking listeners to rate, follow or \
        support this show. The transcript may be in any language. Its lines are numbered like [12]. Answer with the \
        line ranges of the advertising blocks, or an empty list if there is none.
        """

    /// Instructions for small open models, which answer more reliably in plain text (`parseTextAnswer`) than with
    /// guided generation. Measured against hand-labelled episodes (German podcasts with inserted spots and host-read
    /// ads): Gemma 4 E2B finds 8 of 10 ad blocks this way, 0 of 10 with guided generation.
    public static let textInstructions = """
        You find paid advertising in excerpts of a podcast transcript. Lines are numbered like [12].

        Advertising: a sponsor message or commercial – a brand, product or service is promoted to the listeners, \
        usually with an offer, a discount code, a price, a website or legal conditions. Hosts may read it in their own \
        words; it often starts with a transition ("Werbung", "präsentiert von", "unser Partner", "Black Friday") and \
        ends when the normal conversation returns. Several commercials in a row form one block.

        Not advertising: hosts chatting about products, brands or other creators they like or dislike, the show's own \
        intro and outro, asking listeners to rate or write to the show.

        For each advertising block give the WHOLE block: the number of its first line (where the ad begins, including \
        its transition) and of its last line (the last sentence before the conversation continues). Answer with one \
        line per block: first line number, a dash, last line number, then the brand. Example:
        120-131 Brandname
        If there is no advertising, answer: NONE
        """

    /// Reads answers like `120-131 Brand` (one block per line; "NONE" = no ads). Lenient: small models add brackets,
    /// commas or explanations.
    public static func parseTextAnswer(_ text: String) -> [AdBlockCandidate] {
        let pattern = /(\d+)\s*(?:-|–|—|to|bis)\s*(\d+)(.*)/
        let placeholders: Set<String> = ["", "none", "brand", "brandname", "unknown", "?"]
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let match = try? pattern.firstMatch(in: String(line)), let first = Int(match.1), let last = Int(match.2), last >= first else {
                return nil
            }
            var advertiser = String(match.3).trimmingCharacters(in: CharacterSet(charactersIn: " ]),:–-\t"))
            if let end = advertiser.firstIndex(where: { ".(|".contains($0) }) {
                advertiser = String(advertiser[..<end]).trimmingCharacters(in: .whitespaces)
            }
            let name = placeholders.contains(advertiser.lowercased()) || advertiser.count > 40 ? nil : advertiser
            return AdBlockCandidate(firstLine: first, lastLine: last, advertiser: name)
        }
    }

    /// - Parameters:
    ///   - runner: the model to use; `nil` = keyword heuristics.
    ///   - progress: called with values 0…1.
    public func detect(in transcript: HearthModel.Transcript, runner: (any AdModelRunner)?, progress: @Sendable (Double) -> Void = { _ in }) async throws -> AdAnalysis {
        guard let runner else {
            progress(1)
            return AdAnalysis(itemID: transcript.itemID, method: .heuristic, segments: HeuristicAdDetector().detect(in: transcript.segments))
        }
        let windows = Self.requestWindows(for: transcript.segments, runner: runner, overlap: overlapLines)
        let deadline = runner.timeBudget.map { Date.now.addingTimeInterval($0) }
        var found: [AdSegment] = []
        do {
            for (index, window) in windows.enumerated() {
                try Task.checkCancellation()
                let segments = window.flatMap { Array(transcript.segments[$0]) }
                if let deadline, Date.now > deadline {
                    // Over the time budget: the rest is covered by the keyword heuristics.
                    found += HeuristicAdDetector().detect(in: segments)
                    progress(Double(index + 1) / Double(windows.count))
                    continue
                }
                do {
                    let prompt = Self.prompt(for: window, segments: transcript.segments)
                    let blocks = try await Self.withDeadline(deadline) {
                        try await runner.findAds(instructions: Self.instructions, transcript: prompt)
                    }
                    found += Self.adSegments(from: blocks, regions: window, segments: transcript.segments)
                } catch is DeadlineExceeded {
                    found += HeuristicAdDetector().detect(in: segments)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as AnthropicError where error.isFatal {
                    // A wrong key or exhausted credit affects every window: report it instead of hiding it.
                    throw error
                } catch {
                    Self.logger.notice("Window \(index) fell back to heuristics: \(String(describing: error), privacy: .public)")
                    found += HeuristicAdDetector().detect(in: segments)
                }
                progress(Double(index + 1) / Double(windows.count))
            }
        } catch {
            await runner.finish()
            throw error
        }
        if let deadline, Date.now > deadline {
            Self.logger.notice("Ad detection exceeded its time budget; the rest used keywords")
        }
        await runner.finish()
        if runner.extendsToCuePassages {
            found = Self.extended(found, segments: transcript.segments)
        }
        return AdAnalysis(itemID: transcript.itemID, method: runner.method, modelName: runner.modelName, segments: AdAnalysis.normalized(found, joinGap: 8))
    }

    struct DeadlineExceeded: Error {}

    /// Runs `operation`, cancelling it when `deadline` passes (MLX generation stops at cancellation).
    static func withDeadline<T: Sendable>(_ deadline: Date?, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard let deadline else { return try await operation() }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                throw DeadlineExceeded()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw DeadlineExceeded() }
            return result
        }
    }

    /// Widens each found block to the sponsor-cue lines of the candidate passage it lies in (the passage without its
    /// context lines). On hand-labelled episodes this raised the share of ad time found from 45 % to 60 % (Apple
    /// Intelligence) and from 43 % to 56 % (Gemma 4 E2B) at about the same precision.
    static func extended(_ ads: [AdSegment], segments: [TranscriptSegment]) -> [AdSegment] {
        let selector = CandidateSelector()
        let cores: [ClosedRange<TimeInterval>] = selector.regions(in: segments).map { region in
            let low = region.lowerBound == 0 ? 0 : min(region.lowerBound + selector.context, region.upperBound - 1)
            let high = region.upperBound == segments.count ? region.upperBound - 1 : max(region.upperBound - 1 - selector.context, low)
            return segments[low].start ... segments[high].end
        }
        return ads.map { ad in
            var result = ad
            for core in cores where core.lowerBound < ad.end && ad.start < core.upperBound {
                let start = min(result.start, core.lowerBound)
                let end = max(result.end, core.upperBound)
                // A long passage is mostly conversation around a short read: keep the model's boundaries.
                guard end - start <= 6 * 60 else { continue }
                result.start = start
                result.end = end
            }
            return result
        }
    }

    /// The requests to send: each is one or more ranges of segment indices fitting the runner's window. Runners that
    /// read candidates only get the candidate passages, packed together.
    static func requestWindows(for segments: [TranscriptSegment], runner: any AdModelRunner, overlap: Int) -> [[Range<Int>]] {
        guard runner.readsCandidatesOnly else {
            return windows(for: segments, characters: runner.windowCharacters, overlap: overlap).map { [$0] }
        }
        var result: [[Range<Int>]] = []
        var current: [Range<Int>] = []
        var used = 0
        for region in CandidateSelector().regions(in: segments) {
            // A passage longer than a window is split like a whole transcript.
            let pieces = windows(for: Array(segments[region]), characters: runner.windowCharacters, overlap: 0)
                .map { ($0.lowerBound + region.lowerBound) ..< ($0.upperBound + region.lowerBound) }
            for piece in pieces {
                let length = piece.reduce(0) { $0 + line($1, segments[$1]).count + 1 } + 2
                if used + length > runner.windowCharacters, !current.isEmpty {
                    result.append(current)
                    current = []
                    used = 0
                }
                current.append(piece)
                used += length
            }
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    /// Numbered lines of the window's passages; separate passages are divided by "…".
    static func prompt(for window: [Range<Int>], segments: [TranscriptSegment]) -> String {
        let passages = window.map { range in range.map { line($0, segments[$0]) }.joined(separator: "\n") }
        let first = window.first?.lowerBound ?? 0
        let last = (window.last?.upperBound ?? 1) - 1
        let header = window.count > 1
            ? "Excerpts of the transcript (lines \(first) to \(last), gaps marked with …):"
            : "Transcript lines \(first) to \(last):"
        return header + "\n" + passages.joined(separator: "\n…\n")
    }

    /// Converts the model's line ranges into time ranges. A block never spans the gap between two passages (that
    /// would skip content the model never saw): it is cut to the passage it starts in.
    static func adSegments(from blocks: [AdBlockCandidate], regions: [Range<Int>], segments: [TranscriptSegment]) -> [AdSegment] {
        if regions.count == 1, let region = regions.first {
            return adSegments(from: blocks, window: region, segments: segments)
        }
        return blocks.flatMap { block -> [AdSegment] in
            guard let region = regions.first(where: { $0.contains(block.firstLine) }) ?? regions.first(where: { $0.contains(block.lastLine) }) else {
                return []
            }
            return adSegments(from: [block], window: region, segments: segments)
        }
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
    static func adSegments(from blocks: [AdBlockCandidate], window: Range<Int>, segments: [TranscriptSegment]) -> [AdSegment] {
        blocks.compactMap { block in
            let first = min(max(block.firstLine, window.lowerBound), window.upperBound - 1)
            let last = min(max(block.lastLine, first), window.upperBound - 1)
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

    /// Asks a FoundationModels session (Apple Intelligence or an MLX model) for the ad blocks, with guided generation.
    public static func findAds(with session: LanguageModelSession, transcript: String) async throws -> [AdBlockCandidate] {
        let response = try await session.respond(to: transcript, generating: AdWindowResult.self)
        return response.content.ads.map { AdBlockCandidate(firstLine: $0.firstLine, lastLine: $0.lastLine, advertiser: $0.advertiser) }
    }
    #endif
}

#if canImport(FoundationModels)
/// Apple Intelligence's on-device model.
struct SystemModelRunner: AdModelRunner {
    var method: AdAnalysis.Method { .languageModel }
    var extendsToCuePassages: Bool { true }
    var modelName: String? { nil }
    /// ~1 300 tokens, leaving room for instructions, schema and answer within the 4 096 token context.
    var windowCharacters: Int { 4_500 }

    func findAds(instructions: String, transcript: String) async throws -> [AdBlockCandidate] {
        try await AdDetector.findAds(with: LanguageModelSession(instructions: instructions), transcript: transcript)
    }
}
#endif

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
