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
    case fileMove(String)
}

/// `URLSession` delegate for the (background) download session.
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Events: Sendable {
        var progress: @Sendable (_ assetID: String, _ written: Int64, _ expected: Int64) -> Void
        var finished: @Sendable (_ assetID: String, _ result: Result<Int64, any Error>, _ resumeData: Data?) -> Void
        var allEventsDelivered: @Sendable () -> Void
    }

    private let root: URL
    private let trust: SessionTrust
    private let events: Events
    private let logger = Logger(category: "DownloadSession")
    /// Results of `didFinishDownloadingTo`, reported in `didCompleteWithError`.
    private let moved = Mutex<[Int: Result<Int64, any Error>]>([:])
    private let lastReport = Mutex<[Int: Date]>([:])

    init(root: URL, trust: SessionTrust, events: Events) {
        self.root = root
        self.trust = trust
        self.events = events
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let description = DownloadTaskDescription(downloadTask.taskDescription) else { return }
        let result: Result<Int64, any Error>
        if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            result = .failure(DownloadTaskError.httpStatus(response.statusCode))
        } else {
            let destination = root.appending(path: description.relativePath)
            do {
                let manager = FileManager.default
                try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if manager.fileExists(atPath: destination.path) {
                    try manager.removeItem(at: destination)
                }
                try manager.moveItem(at: location, to: destination)
                FileSystem.excludeFromBackup(destination)
                let size = (try? manager.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
                result = .success(size)
            } catch {
                logger.error("Moving download failed: \(error.localizedDescription, privacy: .public)")
                result = .failure(DownloadTaskError.fileMove(error.localizedDescription))
            }
        }
        moved.withLock { $0[downloadTask.taskIdentifier] = result }
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
            events.progress(description.assetID, totalBytesWritten, totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let description = DownloadTaskDescription(task.taskDescription) else { return }
        let movedResult = moved.withLock { $0.removeValue(forKey: task.taskIdentifier) }
        _ = lastReport.withLock { $0.removeValue(forKey: task.taskIdentifier) }
        if let error {
            let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            events.finished(description.assetID, .failure(error), resumeData)
        } else if let movedResult {
            events.finished(description.assetID, movedResult, nil)
        } else {
            events.finished(description.assetID, .failure(DownloadTaskError.fileMove("missing file")), nil)
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
        events.allEventsDelivered()
    }
    #endif
}
