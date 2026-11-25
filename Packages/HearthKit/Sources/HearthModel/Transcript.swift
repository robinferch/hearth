import Foundation

// MARK: - Transcript

/// An on-device transcript of a playable item with word-level timings (absolute item time).
public struct Transcript: Hashable, Codable, Sendable {
    public var itemID: ItemIdentifier
    /// BCP 47 identifier of the recognized language (`de-DE`).
    public var localeIdentifier: String
    public var createdAt: Date
    /// Item duration when the transcript was made.
    public var duration: TimeInterval
    /// Phrases/sentences in time order.
    public var segments: [TranscriptSegment]

    public init(itemID: ItemIdentifier, localeIdentifier: String, createdAt: Date = .now, duration: TimeInterval, segments: [TranscriptSegment]) {
        self.itemID = itemID
        self.localeIdentifier = localeIdentifier
        self.createdAt = createdAt
        self.duration = duration
        self.segments = segments
    }

    public var wordCount: Int { segments.reduce(0) { $0 + max($1.words.count, 1) } }

    /// Plain text with one paragraph per segment.
    public var plainText: String {
        segments.map(\.text).joined(separator: "\n\n")
    }

    /// Index of the segment playing at `time`: the last segment starting at or before `time`, if `time` is not
    /// past its end by more than `tolerance` (pauses between segments keep the previous one).
    public func segmentIndex(at time: TimeInterval, tolerance: TimeInterval = 3) -> Int? {
        guard let index = Self.lastIndex(in: segments, startingAtOrBefore: time, start: \.start) else { return nil }
        return time <= segments[index].end + tolerance ? index : nil
    }

    /// The word playing at `time` within the segment at `segmentIndex`.
    public func wordIndex(at time: TimeInterval, inSegment segmentIndex: Int) -> Int? {
        guard segments.indices.contains(segmentIndex) else { return nil }
        let words = segments[segmentIndex].words
        guard let index = Self.lastIndex(in: words, startingAtOrBefore: time, start: \.start) else { return nil }
        // Between two words the previous one stays highlighted.
        return index
    }

    /// Segments containing `query` (case and diacritic insensitive), in time order.
    public func search(_ query: String) -> [Int] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return segments.indices.filter {
            segments[$0].text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// Groups segments (sentences) into paragraphs for reading: a new paragraph starts after `maximumDuration`, at
    /// pauses longer than `pause`, and wherever one of `breaks` (e.g. ad starts and ends) falls between two segments.
    public func paragraphs(maximumDuration: TimeInterval = 40, pause: TimeInterval = 2.5, breaks: [TimeInterval] = []) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start = 0
        for index in segments.indices.dropFirst() {
            let previous = segments[index - 1]
            let current = segments[index]
            let isLong = current.end - segments[start].start > maximumDuration
            let isPause = current.start - previous.end > pause
            let isBreak = breaks.contains { $0 > previous.start + 0.5 && $0 <= current.start + 0.5 }
            if isLong || isPause || isBreak {
                result.append(start ..< index)
                start = index
            }
        }
        if !segments.isEmpty {
            result.append(start ..< segments.count)
        }
        return result
    }

    static func lastIndex<Element>(in elements: [Element], startingAtOrBefore time: TimeInterval, start: KeyPath<Element, TimeInterval>) -> Int? {
        var low = 0
        var high = elements.count - 1
        var result: Int?
        while low <= high {
            let mid = (low + high) / 2
            if elements[mid][keyPath: start] <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }
}

/// A phrase or sentence of a transcript.
public struct TranscriptSegment: Hashable, Codable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var words: [TranscriptWord]

    public init(start: TimeInterval, end: TimeInterval, text: String, words: [TranscriptWord] = []) {
        self.start = start
        self.end = end
        self.text = text
        self.words = words
    }

    public var duration: TimeInterval { max(0, end - start) }

    enum CodingKeys: String, CodingKey {
        case start = "s"
        case end = "e"
        case text = "t"
        case words = "w"
    }
}

/// A recognized word (or token) with its time range.
public struct TranscriptWord: Hashable, Codable, Sendable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }

    enum CodingKeys: String, CodingKey {
        case text = "t"
        case start = "s"
        case end = "e"
    }
}

// MARK: - Ads

/// A detected advertisement or sponsor read (absolute item time).
public struct AdSegment: Hashable, Codable, Sendable, Identifiable {
    /// Stable within one analysis (index in time order).
    public var id: Int
    public var start: TimeInterval
    public var end: TimeInterval
    /// Advertiser or product, when the detector could name it.
    public var advertiser: String?
    /// 0…1.
    public var confidence: Double

    public init(id: Int, start: TimeInterval, end: TimeInterval, advertiser: String? = nil, confidence: Double) {
        self.id = id
        self.start = start
        self.end = end
        self.advertiser = advertiser
        self.confidence = confidence
    }

    public var duration: TimeInterval { max(0, end - start) }

    public func contains(_ time: TimeInterval) -> Bool {
        time >= start && time < end
    }
}

/// Result of an ad detection run for one item.
public struct AdAnalysis: Hashable, Codable, Sendable {
    public enum Method: String, Codable, Sendable {
        /// Apple Intelligence (on-device language model).
        case languageModel
        /// Keyword heuristics.
        case heuristic
        /// An open model (Gemma, Qwen, …) running on this device.
        case localModel
        /// Claude via the user's own Anthropic API key (the transcript is sent to Anthropic).
        case anthropic
    }

    public var itemID: ItemIdentifier
    public var createdAt: Date
    public var method: Method
    /// Display name of the model that found the ads (local and cloud models).
    public var modelName: String?
    public var segments: [AdSegment]

    public init(itemID: ItemIdentifier, createdAt: Date = .now, method: Method, modelName: String? = nil, segments: [AdSegment]) {
        self.itemID = itemID
        self.createdAt = createdAt
        self.method = method
        self.modelName = modelName
        self.segments = segments
    }

    public var totalDuration: TimeInterval { segments.reduce(0) { $0 + $1.duration } }

    /// Sorts, merges overlapping or nearly adjacent ranges (gap ≤ `joinGap`) and renumbers.
    public static func normalized(_ segments: [AdSegment], joinGap: TimeInterval = 5) -> [AdSegment] {
        let sorted = segments.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var merged: [AdSegment] = []
        for segment in sorted {
            if var last = merged.last, segment.start <= last.end + joinGap {
                last.end = max(last.end, segment.end)
                last.confidence = max(last.confidence, segment.confidence)
                if last.advertiser == nil {
                    last.advertiser = segment.advertiser
                }
                merged[merged.count - 1] = last
            } else {
                merged.append(segment)
            }
        }
        return merged.enumerated().map { index, segment in
            var segment = segment
            segment.id = index
            return segment
        }
    }
}
