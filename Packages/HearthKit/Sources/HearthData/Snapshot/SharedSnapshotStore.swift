import Foundation
import HearthModel
import os
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Writes the snapshot shared with widgets, controls, Live Activities and the watch
/// (`<app group>/Snapshot/snapshot.json` + small JPEG covers).
@MainActor
public final class SharedSnapshotStore {
    nonisolated static let fileName = "snapshot.json"
    nonisolated static let coverPixelSize = 200

    public nonisolated static var imagesDirectory: URL { AppGroup.directory("Snapshot") }

    private let environment: DataEnvironment
    private var current: SharedSnapshot
    private var reloadTask: Task<Void, Never>?
    private let logger = Logger(category: "SharedSnapshotStore")
    weak var hearth: HearthData?

    private var directory: URL { environment.snapshotURL }
    private var fileURL: URL { directory.appending(path: Self.fileName) }

    init(environment: DataEnvironment) {
        self.environment = environment
        current = Self.read(from: environment.snapshotURL.appending(path: Self.fileName))
    }

    /// Readable from any process (widgets).
    public nonisolated static func read() -> SharedSnapshot {
        read(from: imagesDirectory.appending(path: fileName))
    }

    nonisolated static func read(from url: URL) -> SharedSnapshot {
        JSON.decode(SharedSnapshot.self, from: try? Data(contentsOf: url)) ?? SharedSnapshot()
    }

    /// The last written snapshot of this process.
    public var snapshot: SharedSnapshot { current }

    /// URL of a cover file referenced by an entry.
    public nonisolated static func coverURL(_ fileName: String) -> URL {
        imagesDirectory.appending(path: fileName)
    }

    /// Mutates and persists the snapshot, then reloads widgets/controls (debounced).
    public func update(_ mutate: (inout SharedSnapshot) -> Void) {
        var updated = current
        mutate(&updated)
        updated.updatedAt = current.updatedAt
        guard updated != current else { return }
        updated.updatedAt = .now
        current = updated
        write(updated)
        scheduleReload()
    }

    private func write(_ snapshot: SharedSnapshot) {
        guard let data = JSON.encode(snapshot) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Writing snapshot failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func scheduleReload() {
        guard environment.isLive else { return }
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
            #if os(iOS)
            ControlCenter.shared.reloadAllControls()
            #endif
            #endif
        }
    }

    /// Writes a small cover for `id` into the snapshot images directory, returns the file name.
    public func storeCover(for id: ItemIdentifier) async -> String? {
        let name = "\(ImageStore.baseKey(id))-\(id.connectionID).jpg".replacingOccurrences(of: "/", with: "_")
        let url = directory.appending(path: name)
        if FileManager.default.fileExists(atPath: url.path) {
            return name
        }
        guard let data = await hearth?.images.imageData(for: id, size: .tiny) else { return nil }
        let written = await Task.detached(priority: .utility) {
            guard let jpeg = ImageProcessing.jpegThumbnail(from: data, maxPixelSize: Self.coverPixelSize) else { return false }
            return (try? jpeg.write(to: url, options: .atomic)) != nil
        }.value
        return written ? name : nil
    }

    /// Deletes cover files no longer referenced by the snapshot.
    func removeUnusedCovers() {
        var used = Set(current.listenNow.compactMap(\.coverFile))
        if let file = current.nowPlaying?.coverFile {
            used.insert(file)
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for file in files where file.hasSuffix(".jpg") && !used.contains(file) {
            try? FileManager.default.removeItem(at: directory.appending(path: file))
        }
    }
}
