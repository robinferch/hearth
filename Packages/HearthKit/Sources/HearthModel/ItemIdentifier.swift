import Foundation

/// Stable identifier for any entity on any connected audiobookshelf server.
///
/// String form: `TYPE::CONNECTION::LIBRARY::PRIMARY[::GROUPING]`.
/// - `primaryID` is the server id of the entity itself (the episode id for episodes).
/// - `groupingID` is only set for episodes and holds the podcast's library item id.
public struct ItemIdentifier: Hashable, Codable, Sendable, CustomStringConvertible, LosslessStringConvertible {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case audiobook
        case author
        case narrator
        case series
        case podcast
        case episode
        case collection
        case playlist

        public var isPlayable: Bool {
            self == .audiobook || self == .episode
        }
    }

    public let kind: Kind
    public let connectionID: ConnectionID
    public let libraryID: String
    public let primaryID: String
    public let groupingID: String?

    public init(kind: Kind, connectionID: ConnectionID, libraryID: String, primaryID: String, groupingID: String? = nil) {
        self.kind = kind
        self.connectionID = connectionID
        self.libraryID = libraryID
        self.primaryID = primaryID
        self.groupingID = groupingID
    }

    private static let separator = "::"

    public var description: String {
        var parts = [kind.rawValue, connectionID, libraryID, primaryID]
        if let groupingID {
            parts.append(groupingID)
        }
        return parts.joined(separator: Self.separator)
    }

    public init?(_ description: String) {
        let parts = description.components(separatedBy: Self.separator)
        guard parts.count == 4 || parts.count == 5, let kind = Kind(rawValue: parts[0]) else {
            return nil
        }
        self.init(kind: kind, connectionID: parts[1], libraryID: parts[2], primaryID: parts[3], groupingID: parts.count == 5 ? parts[4] : nil)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let identifier = ItemIdentifier(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid item identifier: \(string)")
        }
        self = identifier
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    // Equality ignores the kind: an episode referenced from a playlist is the same episode.
    public static func == (lhs: ItemIdentifier, rhs: ItemIdentifier) -> Bool {
        lhs.connectionID == rhs.connectionID
            && lhs.libraryID == rhs.libraryID
            && lhs.primaryID == rhs.primaryID
            && lhs.groupingID == rhs.groupingID
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(connectionID)
        hasher.combine(libraryID)
        hasher.combine(primaryID)
        hasher.combine(groupingID)
    }
}

public extension ItemIdentifier {
    /// The library item id used in `api/items/{id}` paths.
    var apiItemID: String { groupingID ?? primaryID }

    /// The episode id when this identifier refers to an episode.
    var apiEpisodeID: String? { groupingID == nil ? nil : primaryID }

    /// `itemID` or `itemID/episodeID`.
    var pathComponent: String {
        if let groupingID {
            "\(groupingID)/\(primaryID)"
        } else {
            primaryID
        }
    }

    var isPlayable: Bool { kind.isPlayable }

    var library: LibraryIdentifier {
        LibraryIdentifier(connectionID: connectionID, libraryID: libraryID)
    }

    /// The identifier of the podcast that contains this episode.
    var podcastIdentifier: ItemIdentifier? {
        guard kind == .episode, let groupingID else { return nil }
        return ItemIdentifier(kind: .podcast, connectionID: connectionID, libraryID: libraryID, primaryID: groupingID)
    }

    /// Filesystem-safe representation.
    var fileSafe: String {
        description.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "-")
    }
}

public typealias ConnectionID = String

public struct LibraryIdentifier: Hashable, Codable, Sendable, CustomStringConvertible {
    public let connectionID: ConnectionID
    public let libraryID: String

    public init(connectionID: ConnectionID, libraryID: String) {
        self.connectionID = connectionID
        self.libraryID = libraryID
    }

    public var description: String { "\(connectionID)::\(libraryID)" }
}
