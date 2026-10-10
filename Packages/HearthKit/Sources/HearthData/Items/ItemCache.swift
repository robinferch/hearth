import Foundation
import HearthModel

/// Small LRU dictionary (main-actor confined by its owner).
struct LRUCache<Key: Hashable, Value> {
    private var storage: [Key: (value: Value, tick: UInt64)] = [:]
    private var tick: UInt64 = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int { storage.count }

    mutating func value(for key: Key) -> Value? {
        guard let entry = storage[key] else { return nil }
        tick &+= 1
        storage[key] = (entry.value, tick)
        return entry.value
    }

    func peek(_ key: Key) -> Value? {
        storage[key]?.value
    }

    mutating func set(_ value: Value, for key: Key) {
        tick &+= 1
        storage[key] = (value, tick)
        if storage.count > capacity {
            // Evict the oldest ~10 % in one go to amortise the scan.
            let overflow = storage.count - capacity + max(1, capacity / 10)
            let oldest = storage.sorted { $0.value.tick < $1.value.tick }.prefix(overflow).map(\.key)
            for key in oldest {
                storage[key] = nil
            }
        }
    }

    mutating func remove(_ key: Key) {
        storage[key] = nil
    }

    mutating func removeAll(where predicate: (Key) -> Bool = { _ in true }) {
        storage = storage.filter { !predicate($0.key) }
    }
}

/// JSON files under `<caches>/Items/<connection>/`.
struct ItemDiskCache: Sendable {
    let root: URL

    struct PodcastEntry: Codable, Sendable {
        var podcast: Podcast
        var episodes: [Episode]
    }

    private func url(_ id: ItemIdentifier, suffix: String) -> URL {
        root.appending(path: id.connectionID, directoryHint: .isDirectory)
            .appending(path: "\(id.kind.rawValue)-\(id.storageKey.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "/", with: "_")).\(suffix).json")
    }

    func readItem(_ id: ItemIdentifier) async -> AnyItem? {
        let url = url(id, suffix: "item")
        return await Task.detached(priority: .utility) {
            JSON.decode(AnyItem.self, from: try? Data(contentsOf: url))
        }.value
    }

    func readPodcast(_ id: ItemIdentifier) async -> PodcastEntry? {
        let url = url(id, suffix: "podcast")
        return await Task.detached(priority: .utility) {
            JSON.decode(PodcastEntry.self, from: try? Data(contentsOf: url))
        }.value
    }

    func write(_ item: AnyItem) {
        let url = url(item.id, suffix: "item")
        Task.detached(priority: .utility) {
            Self.write(JSON.encode(item), to: url)
        }
    }

    func write(_ entry: PodcastEntry) {
        let url = url(entry.podcast.id, suffix: "podcast")
        Task.detached(priority: .utility) {
            Self.write(JSON.encode(entry), to: url)
        }
    }

    private static func write(_ data: Data?, to url: URL) {
        guard let data else { return }
        FileSystem.ensureDirectory(url.deletingLastPathComponent())
        try? data.write(to: url, options: .atomic)
    }

    func remove(_ id: ItemIdentifier) {
        try? FileManager.default.removeItem(at: url(id, suffix: "item"))
        try? FileManager.default.removeItem(at: url(id, suffix: "podcast"))
    }

    func remove(connection: ConnectionID) {
        try? FileManager.default.removeItem(at: root.appending(path: connection, directoryHint: .isDirectory))
    }

    func removeAll() {
        FileSystem.removeContents(of: root)
    }
}
