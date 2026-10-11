import Foundation
import HearthModel

public extension DownloadManager {
    /// Items currently downloading (the watch's Downloads screen shows them above finished downloads).
    /// Observable: re-evaluated when the set of downloads changes.
    var activeDownloadIDs: [ItemIdentifier] {
        // Registers observation of the download list revision.
        _ = downloadedEpisodes()
        return presentItems()
            .filter { status(of: $0) == .downloading }
            .sorted { $0.description < $1.description }
    }
}
