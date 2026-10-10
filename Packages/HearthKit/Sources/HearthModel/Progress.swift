import Foundation

/// Listening progress of a playable item.
public struct ProgressEntity: Hashable, Codable, Sendable, Identifiable {
    /// Server progress id, or a local UUID until the server assigned one.
    public var id: String
    public var itemID: ItemIdentifier
    public var progress: Double
    public var duration: TimeInterval?
    public var currentTime: TimeInterval
    public var startedAt: Date?
    public var lastUpdate: Date
    public var finishedAt: Date?
    public var hideFromContinueListening: Bool

    public init(id: String, itemID: ItemIdentifier, progress: Double, duration: TimeInterval?, currentTime: TimeInterval, startedAt: Date?, lastUpdate: Date, finishedAt: Date?, hideFromContinueListening: Bool = false) {
        self.id = id
        self.itemID = itemID
        self.progress = progress
        self.duration = duration
        self.currentTime = currentTime
        self.startedAt = startedAt
        self.lastUpdate = lastUpdate
        self.finishedAt = finishedAt
        self.hideFromContinueListening = hideFromContinueListening
    }

    public var isFinished: Bool { progress >= 1 }
    public var isInProgress: Bool { progress > 0 && progress < 1 }

    public var remaining: TimeInterval? {
        guard let duration, duration > 0 else { return nil }
        return max(0, duration - currentTime)
    }

    public static func empty(for itemID: ItemIdentifier) -> ProgressEntity {
        ProgressEntity(id: UUID().uuidString, itemID: itemID, progress: 0, duration: nil, currentTime: 0, startedAt: nil, lastUpdate: .distantPast, finishedAt: nil)
    }
}

public enum DownloadStatus: String, Codable, Sendable {
    case none
    case downloading
    case completed
}

public enum UpNextStrategy: String, Codable, Sendable, CaseIterable {
    case `default`
    case listenNow
    case disabled
}

public enum AutoDownloadRule: Hashable, Codable, Sendable {
    case disabled
    case all
    case nextUnfinished(count: Int)
    case releasedWithin(hours: Int)
}
