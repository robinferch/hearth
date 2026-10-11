import Foundation
import HearthModel
import os
import Synchronization

/// Relative file locations of downloads: `<connection>/<library>/<primary>/<file>`.
enum DownloadPaths {
    private static func safe(_ component: String) -> String {
        let cleaned = component.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "_" }
        let string = String(cleaned)
        return string.isEmpty ? "_" : string
    }

    static func directory(for id: ItemIdentifier) -> String {
        [id.connectionID, id.libraryID.isEmpty ? "_" : id.libraryID, id.primaryID].map(safe).joined(separator: "/")
    }

    static func audio(_ id: ItemIdentifier, index: Int, fileExtension: String) -> String {
        let ext = safe(fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased())
        return "\(directory(for: id))/audio-\(index).\(ext.isEmpty || ext == "_" ? "m4b" : ext)"
    }

    static func cover(_ id: ItemIdentifier, size: ImageSize) -> String {
        "\(directory(for: id))/cover-\(size.rawValue).img"
    }

    static func pdf(_ id: ItemIdentifier, ino: String) -> String {
        "\(directory(for: id))/document-\(safe(ino)).pdf"
    }
}

/// Encodes the asset a task belongs to in `URLSessionTask.taskDescription`, so the delegate can place files without
/// consulting the main actor (the temporary file must be moved before the callback returns).
struct DownloadTaskDescription: Sendable, Equatable {
    var assetID: String
    var relativePath: String

    var encoded: String { "\(assetID)|\(relativePath)" }

    init(assetID: String, relativePath: String) {
        self.assetID = assetID
        self.relativePath = relativePath
    }

    init?(_ string: String?) {
        guard let string, let separator = string.firstIndex(of: "|") else { return nil }
        assetID = String(string[..<separator])
        relativePath = String(string[string.index(after: separator)...])
        guard !assetID.isEmpty, !relativePath.isEmpty else { return nil }
    }
}

enum DownloadTaskError: Error, Sendable {
    case httpStatus(Int)
    /// 401; carries the rejected request so the token can be refreshed.
    case unauthorized(URLRequest?)
    case fileMove(String)
    /// The asset was removed while its task was running; the file was not kept.
    case discarded
}

/// Ids of assets that may currently be written to disk. Shared between the main actor (which registers and removes
/// assets) and the session delegate (which moves finished files), so a task that finishes while its download is
/// being removed can't recreate the deleted directory.
final class ActiveDownloadAssets: Sendable {
    private let ids = Mutex<Set<String>>([])

    func insert(_ assetIDs: some Sequence<String>) {
        ids.withLock { $0.formUnion(assetIDs) }
    }

    /// Removes the ids. Waits for a file move of one of them that is in progress.
    func remove(_ assetIDs: some Sequence<String>) {
        ids.withLock { $0.subtract(assetIDs) }
    }

    func contains(_ assetID: String) -> Bool {
        ids.withLock { $0.contains(assetID) }
    }

    /// Runs `body` while holding the lock if `assetID` is active; `nil` otherwise.
    func ifActive<T>(_ assetID: String, _ body: () -> T) -> T? {
        ids.withLock { ids in
            ids.contains(assetID) ? body() : nil
        }
    }
}

/// Download session callbacks, delivered in order.
enum DownloadEvent: Sendable {
    case progress(assetID: String, written: Int64, expected: Int64)
    case finished(assetID: String, taskIdentifier: Int, result: Result<Int64, any Error>, resumeData: Data?)
    /// `urlSessionDidFinishEvents(forBackgroundURLSession:)`.
    case allEventsDelivered
    /// Re-check pending background completion handlers (queued behind earlier events).
    case drainBackgroundCompletions
}

/// `URLSession` delegate for the (background) download session.
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let root: URL
    private let trust: SessionTrust
    private let active: ActiveDownloadAssets
    private let send: @Sendable (DownloadEvent) -> Void
    private let logger = Logger(category: "DownloadSession")
    /// Results of `didFinishDownloadingTo`, reported in `didCompleteWithError`.
    private let moved = Mutex<[Int: Result<Int64, any Error>]>([:])
    private let lastReport = Mutex<[Int: Date]>([:])

    init(root: URL, trust: SessionTrust, active: ActiveDownloadAssets, send: @escaping @Sendable (DownloadEvent) -> Void) {
        self.root = root
        self.trust = trust
        self.active = active
        self.send = send
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let description = DownloadTaskDescription(downloadTask.taskDescription) else { return }
        let result: Result<Int64, any Error>
        if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            if response.statusCode == 401 {
                result = .failure(DownloadTaskError.unauthorized(downloadTask.originalRequest))
            } else {
                result = .failure(DownloadTaskError.httpStatus(response.statusCode))
            }
        } else {
            // Moved while holding the lock so a concurrent removal can't delete the directory in between.
            result = active.ifActive(description.assetID) {
                move(location, to: root.appending(path: description.relativePath))
            } ?? .failure(DownloadTaskError.discarded)
        }
        moved.withLock { $0[downloadTask.taskIdentifier] = result }
    }

    private func move(_ location: URL, to destination: URL) -> Result<Int64, any Error> {
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.moveItem(at: location, to: destination)
            FileSystem.excludeFromBackup(destination)
            let size = (try? manager.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
            return .success(size)
        } catch {
            logger.error("Moving download failed: \(error.localizedDescription, privacy: .public)")
            return .failure(DownloadTaskError.fileMove(error.localizedDescription))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let description = DownloadTaskDescription(downloadTask.taskDescription) else { return }
        // Throttle to ~4 updates per second per task.
        let now = Date.now
        let shouldReport = lastReport.withLock { reports in
            if let last = reports[downloadTask.taskIdentifier], now.timeIntervalSince(last) < 0.25 {
                return false
            }
            reports[downloadTask.taskIdentifier] = now
            return true
        }
        if shouldReport {
            send(.progress(assetID: description.assetID, written: totalBytesWritten, expected: totalBytesExpectedToWrite))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let description = DownloadTaskDescription(task.taskDescription) else { return }
        let movedResult = moved.withLock { $0.removeValue(forKey: task.taskIdentifier) }
        _ = lastReport.withLock { $0.removeValue(forKey: task.taskIdentifier) }
        if let error {
            let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            send(.finished(assetID: description.assetID, taskIdentifier: task.taskIdentifier, result: .failure(error), resumeData: resumeData))
        } else if let movedResult {
            send(.finished(assetID: description.assetID, taskIdentifier: task.taskIdentifier, result: movedResult, resumeData: nil))
        } else {
            send(.finished(assetID: description.assetID, taskIdentifier: task.taskIdentifier, result: .failure(DownloadTaskError.fileMove("missing file")), resumeData: nil))
        }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        trust.handle(challenge)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        trust.handle(challenge)
    }

    #if !os(macOS)
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        send(.allEventsDelivered)
    }
    #endif
}
