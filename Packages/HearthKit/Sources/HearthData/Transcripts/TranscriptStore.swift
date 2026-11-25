import CryptoKit
import Foundation
import HearthModel
import Observation
import os

/// On-device transcripts and detected ad segments.
///
/// - Transcripts are JSON files in `Application Support/Transcripts` (≈ 1 MB per two hours) and are loaded on demand.
/// - An index (which items have a transcript) and all ad analyses (small) live in memory, so the player can check
///   the ad segments of the current item on every tick.
@MainActor
@Observable
public final class TranscriptStore {
    /// Index entry of a stored transcript.
    public struct Entry: Hashable, Codable, Sendable {
        public var itemID: ItemIdentifier
        public var localeIdentifier: String
        public var createdAt: Date
        public var duration: TimeInterval
        public var wordCount: Int
    }

    private struct Index: Codable {
        var entries: [Entry] = []
        var ads: [AdAnalysis] = []
    }

    public private(set) var entries: [ItemIdentifier: Entry] = [:]
    public private(set) var adAnalyses: [ItemIdentifier: AdAnalysis] = [:]

    @ObservationIgnored let environment: DataEnvironment
    @ObservationIgnored weak var hearth: HearthData?
    @ObservationIgnored private let logger = Logger(category: "TranscriptStore")
    /// The most recently used transcript (the player panel and the transcript screen ask repeatedly).
    @ObservationIgnored private var cached: Transcript?

    var directory: URL { environment.supportURL.appending(path: "Transcripts", directoryHint: .isDirectory) }
    private var indexURL: URL { directory.appending(path: "index.json") }

    init(environment: DataEnvironment) {
        self.environment = environment
        FileSystem.ensureDirectory(directory)
        if let index = JSON.decode(Index.self, from: try? Data(contentsOf: indexURL)) {
            entries = Dictionary(index.entries.map { ($0.itemID, $0) }, uniquingKeysWith: { $1 })
            adAnalyses = Dictionary(index.ads.map { ($0.itemID, $0) }, uniquingKeysWith: { $1 })
        }
    }

    // MARK: Transcripts

    public func hasTranscript(_ id: ItemIdentifier) -> Bool {
        entries[id] != nil
    }

    public func entry(for id: ItemIdentifier) -> Entry? {
        entries[id]
    }

    /// Loads a transcript from disk (off the main actor).
    public func transcript(for id: ItemIdentifier) async -> Transcript? {
        if let cached, cached.itemID == id {
            return cached
        }
        guard entries[id] != nil else { return nil }
        let url = fileURL(for: id)
        let transcript = await Task.detached(priority: .userInitiated) {
            JSON.decode(Transcript.self, from: try? Data(contentsOf: url))
        }.value
        if let transcript {
            cached = transcript
        } else {
            logger.error("The transcript of \(id, privacy: .public) couldn't be read")
        }
        return transcript
    }

    public func save(_ transcript: Transcript) async throws {
        let url = fileURL(for: transcript.itemID)
        try await Task.detached(priority: .utility) {
            let data = try JSON.encoder.encode(transcript)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }.value
        cached = transcript
        entries[transcript.itemID] = Entry(
            itemID: transcript.itemID,
            localeIdentifier: transcript.localeIdentifier,
            createdAt: transcript.createdAt,
            duration: transcript.duration,
            wordCount: transcript.wordCount
        )
        saveIndex()
    }

    /// Deletes the transcript and the ad analysis of an item.
    public func remove(_ id: ItemIdentifier) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
        entries[id] = nil
        adAnalyses[id] = nil
        if cached?.itemID == id {
            cached = nil
        }
        saveIndex()
    }

    public func removeAll() {
        FileSystem.removeContents(of: directory)
        entries = [:]
        adAnalyses = [:]
        cached = nil
        saveIndex()
    }

    func forget(connection id: ConnectionID) {
        for itemID in Set(entries.keys).union(adAnalyses.keys) where itemID.connectionID == id {
            remove(itemID)
        }
    }

    public func storageUsed() async -> Int64 {
        let directory = directory
        return await Task.detached(priority: .utility) { FileSystem.size(of: directory) }.value
    }

    // MARK: Ads

    public func adAnalysis(for id: ItemIdentifier) -> AdAnalysis? {
        adAnalyses[id]
    }

    /// Detected ad segments of an item in time order (empty when not analyzed).
    public func adSegments(for id: ItemIdentifier) -> [AdSegment] {
        adAnalyses[id]?.segments ?? []
    }

    public func saveAds(_ analysis: AdAnalysis) {
        adAnalyses[analysis.itemID] = analysis
        saveIndex()
    }

    public func removeAds(for id: ItemIdentifier) {
        adAnalyses[id] = nil
        saveIndex()
    }

    // MARK: Files

    private func fileURL(for id: ItemIdentifier) -> URL {
        // Identifiers may contain characters that don't belong in file names.
        let digest = SHA256.hash(data: Data(id.description.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(digest).json")
    }

    private func saveIndex() {
        let index = Index(entries: Array(entries.values), ads: Array(adAnalyses.values))
        guard let data = JSON.encode(index) else { return }
        do {
            try data.write(to: indexURL, options: .atomic)
        } catch {
            logger.error("Saving the transcript index failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
