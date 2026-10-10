import Foundation
import HearthData
import HearthModel

/// Snapshot of an item's progress and download state, read from the observable HearthData stores.
///
/// Reading this inside a view's `body` registers observation, so the view re-renders when the
/// item's progress or download state changes.
@MainActor
public struct ItemStatus: Equatable {
    public var progress: ProgressEntity?
    public var download: DownloadStatus
    public var downloadProgress: Double

    public init(progress: ProgressEntity?, download: DownloadStatus, downloadProgress: Double) {
        self.progress = progress
        self.download = download
        self.downloadProgress = downloadProgress
    }

    public static func of(_ id: ItemIdentifier) -> ItemStatus {
        let data = HearthData.shared
        let status = data.downloads.status(of: id)
        return ItemStatus(
            progress: data.progress.progress(for: id),
            download: status,
            downloadProgress: status == .downloading ? data.downloads.progress(of: id) : 0
        )
    }

    /// 0...1
    public var fraction: Double { min(max(progress?.progress ?? 0, 0), 1) }
    public var isFinished: Bool { progress?.isFinished ?? false }
    public var isInProgress: Bool { progress?.isInProgress ?? false }
    public var isDownloaded: Bool { download == .completed }
    public var isDownloading: Bool { download == .downloading }

    /// Remaining seconds based on progress (falls back to `duration`).
    public func remaining(duration: TimeInterval) -> TimeInterval {
        if let remaining = progress?.remaining, isInProgress {
            return remaining
        }
        if isInProgress {
            return max(0, duration * (1 - fraction))
        }
        return duration
    }

    /// The playback rate that will be used for this item (item → global default).
    public static func effectiveRate(for id: ItemIdentifier) -> Double {
        HearthData.shared.itemSettings.playbackRate(for: id) ?? AppSettings.shared.defaultPlaybackRate
    }

    /// Accessibility value such as "42 %, downloaded".
    public var accessibilityValue: String {
        var parts: [String] = []
        if isFinished {
            parts.append(loc("Finished"))
        } else if isInProgress {
            parts.append(HearthFormat.percent(fraction))
        }
        switch download {
        case .completed: parts.append(loc("Downloaded"))
        case .downloading: parts.append(String(localized: "Downloading, \(HearthFormat.percent(downloadProgress))", bundle: .module))
        case .none: break
        }
        return parts.joined(separator: ", ")
    }
}
