import Foundation
import HearthAPI
import HearthModel
import os
import Synchronization

/// Disk + memory cache for covers and author images (raw image data, platform independent).
///
/// Lookup order: memory → downloaded cover → disk cache → server (`coverRequest`) → any other cached size.
public final class ImageStore: Sendable {
    struct Dependencies: Sendable {
        var client: @Sendable (ConnectionID) async -> (any AudiobookshelfClient)?
        var localCover: @Sendable (ItemIdentifier, ImageSize) async -> URL?
    }

    private struct Memory {
        var entries: [String: (data: Data, tick: UInt64)] = [:]
        var bytes = 0
        var tick: UInt64 = 0
    }

    static let memoryLimit = 48 * 1024 * 1024

    private let root: URL
    private let dependencies = Mutex<Dependencies?>(nil)
    private let memory = Mutex(Memory())
    private let colors = Mutex<[String: RGBColor]>([:])
    private let inflight = InflightRequests()
    private let session: URLSession
    private let logger = Logger(category: "ImageStore")

    /// Off in test environments (mock clients hand out unreachable URLs).
    private let allowsNetwork: Bool

    init(environment: DataEnvironment) {
        allowsNetwork = environment.isLive
        root = environment.cachesURL.appending(path: "Images", directoryHint: .isDirectory)
        FileSystem.ensureDirectory(root)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: configuration, delegate: TrustDelegate(trust: environment.trust), delegateQueue: nil)
    }

    func configure(_ dependencies: Dependencies) {
        self.dependencies.withLock { $0 = dependencies }
    }

    // MARK: Keys

    /// Covers are shared by a podcast and its episodes (the server serves the podcast cover for both).
    static func baseKey(_ id: ItemIdentifier) -> String {
        id.kind == .author ? "author-\(id.primaryID)" : "item-\(id.apiItemID)"
    }

    private func fileURL(_ id: ItemIdentifier, size: ImageSize) -> URL {
        root.appending(path: id.connectionID, directoryHint: .isDirectory).appending(path: "\(Self.baseKey(id))-\(size.rawValue).img")
    }

    private func colorURL(_ id: ItemIdentifier) -> URL {
        root.appending(path: id.connectionID, directoryHint: .isDirectory).appending(path: "\(Self.baseKey(id)).color.json")
    }

    private static func memoryKey(_ id: ItemIdentifier, _ size: ImageSize) -> String {
        "\(id.connectionID)|\(baseKey(id))|\(size.rawValue)"
    }

    // MARK: Memory

    private func memoryData(_ key: String) -> Data? {
        memory.withLock { memory in
            guard let entry = memory.entries[key] else { return nil }
            memory.tick &+= 1
            memory.entries[key] = (entry.data, memory.tick)
            return entry.data
        }
    }

    private func remember(_ data: Data, key: String) {
        memory.withLock { memory in
            memory.tick &+= 1
            if let existing = memory.entries[key] {
                memory.bytes -= existing.data.count
            }
            memory.entries[key] = (data, memory.tick)
            memory.bytes += data.count
            if memory.bytes > Self.memoryLimit {
                for (key, entry) in memory.entries.sorted(by: { $0.value.tick < $1.value.tick }) {
                    guard memory.bytes > Self.memoryLimit * 3 / 4 else { break }
                    memory.entries[key] = nil
                    memory.bytes -= entry.data.count
                }
            }
        }
    }

    // MARK: Loading

    /// Returns cached or fetched image data. Uses downloaded covers first.
    public func imageData(for id: ItemIdentifier, size: ImageSize) async -> Data? {
        let key = Self.memoryKey(id, size)
        if let data = memoryData(key) {
            return data
        }
        let dependencies = dependencies.withLock { $0 }

        if id.kind != .author, let local = await dependencies?.localCover(id, size), let data = await Self.read(local) {
            remember(data, key: key)
            return data
        }
        let file = fileURL(id, size: size)
        if let data = await Self.read(file) {
            remember(data, key: key)
            return data
        }
        if allowsNetwork, let client = await dependencies?.client(id.connectionID) {
            let session = session
            let logger = logger
            let fetched = await inflight.run(key: key) {
                do {
                    let request = try await client.coverRequest(for: id, size: size)
                    let (data, response) = try await session.data(for: request)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else { return nil }
                    Self.write(data, to: file)
                    return data
                } catch {
                    logger.debug("Image request failed: \(String(describing: error), privacy: .public)")
                    return nil
                }
            }
            if let fetched {
                remember(fetched, key: key)
                return fetched
            }
        }
        // Offline: any other size we have.
        for other in ImageSize.allCases.sorted(by: { abs($0.rawValue - size.rawValue) < abs($1.rawValue - size.rawValue) }) where other != size {
            if let data = memoryData(Self.memoryKey(id, other)) {
                return data
            }
            if let data = await Self.read(fileURL(id, size: other)) {
                return data
            }
        }
        return nil
    }

    private static func read(_ url: URL) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
            return data
        }.value
    }

    private static func write(_ data: Data, to url: URL) {
        FileSystem.ensureDirectory(url.deletingLastPathComponent())
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Colors

    /// Dominant color of the cover as sRGB components (0...1), cached.
    public func dominantColor(for id: ItemIdentifier) async -> RGBColor? {
        let key = "\(id.connectionID)|\(Self.baseKey(id))"
        if let color = colors.withLock({ $0[key] }) {
            return color
        }
        let url = colorURL(id)
        if let color = JSON.decode(RGBColor.self, from: await Self.read(url)) {
            colors.withLock { $0[key] = color }
            return color
        }
        guard let data = await imageData(for: id, size: .tiny) else { return nil }
        let color = await Task.detached(priority: .utility) { DominantColor.compute(from: data) }.value
        if let color {
            colors.withLock { $0[key] = color }
            if let encoded = JSON.encode(color) {
                Self.write(encoded, to: url)
            }
        }
        return color
    }

    // MARK: Purging

    public func purge() async {
        memory.withLock { $0 = Memory() }
        colors.withLock { $0 = [:] }
        let root = root
        await Task.detached(priority: .utility) { FileSystem.removeContents(of: root) }.value
    }

    func purge(connection: ConnectionID) async {
        memory.withLock { memory in
            for key in memory.entries.keys where key.hasPrefix("\(connection)|") {
                if let entry = memory.entries.removeValue(forKey: key) {
                    memory.bytes -= entry.data.count
                }
            }
        }
        colors.withLock { colors in
            colors = colors.filter { !$0.key.hasPrefix("\(connection)|") }
        }
        try? FileManager.default.removeItem(at: root.appending(path: connection, directoryHint: .isDirectory))
    }
}

/// Coalesces concurrent requests for the same key.
private actor InflightRequests {
    private var tasks: [String: Task<Data?, Never>] = [:]

    func run(key: String, _ operation: @escaping @Sendable () async -> Data?) async -> Data? {
        if let task = tasks[key] {
            return await task.value
        }
        let task = Task { await operation() }
        tasks[key] = task
        let value = await task.value
        tasks[key] = nil
        return value
    }
}

/// Session delegate applying pinned certificates / client identities.
final class TrustDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let trust: SessionTrust

    init(trust: SessionTrust) {
        self.trust = trust
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        trust.handle(challenge)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        trust.handle(challenge)
    }
}
