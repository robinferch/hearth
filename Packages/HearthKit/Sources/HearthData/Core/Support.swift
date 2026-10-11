import Foundation
import HearthModel
import os

extension Logger {
    static let hearthSubsystem = Bundle.main.bundleIdentifier ?? "me.robinferch.hearth"

    init(category: String) {
        self.init(subsystem: Self.hearthSubsystem, category: category)
    }
}

extension ItemIdentifier {
    /// Kind- and library-independent storage key. Server ids are unique per server, and progress/bookmark payloads
    /// from audiobookshelf don't carry a library id, so records are matched on connection + ids only.
    var storageKey: String {
        var parts = [connectionID, primaryID]
        if let groupingID {
            parts.append(groupingID)
        }
        return parts.joined(separator: "::")
    }
}

extension AnyItem {
    /// Lowercased, diacritic-insensitive text used for local search.
    var searchText: String {
        var parts = [name]
        parts += base.authors
        switch self {
        case .audiobook(let audiobook):
            parts += audiobook.narrators
            parts += audiobook.series.map(\.name)
            if let subtitle = audiobook.subtitle { parts.append(subtitle) }
        case .episode(let episode):
            parts.append(episode.podcastName)
        default:
            break
        }
        return SearchRanker.normalize(parts.joined(separator: " "))
    }
}

extension AnyPlayableItem {
    var releaseDate: Date? {
        switch self {
        case .audiobook(let audiobook): audiobook.addedAt
        case .episode(let episode): episode.publishedAt ?? episode.addedAt
        }
    }
}

enum JSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    static func encode<T: Encodable>(_ value: T) -> Data? {
        try? encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? decoder.decode(type, from: data)
    }
}

enum FileSystem {
    /// Recursive allocated size of a directory in bytes.
    static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    static func removeContents(of url: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        for item in contents {
            try? FileManager.default.removeItem(at: item)
        }
    }

    static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    static func ensureDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

/// Runs async operations concurrently and returns the results in input order (failures dropped).
func concurrentCompactMap<Input: Sendable, Output: Sendable>(_ inputs: [Input], _ transform: @escaping @Sendable (Input) async -> Output?) async -> [Output] {
    await withTaskGroup(of: (Int, Output?).self) { group in
        for (index, input) in inputs.enumerated() {
            group.addTask { (index, await transform(input)) }
        }
        var results = [(Int, Output)]()
        for await (index, output) in group {
            if let output {
                results.append((index, output))
            }
        }
        return results.sorted { $0.0 < $1.0 }.map(\.1)
    }
}

extension Calendar {
    func startOfNextDay(after date: Date) -> Date {
        let start = startOfDay(for: date)
        return self.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    }
}
