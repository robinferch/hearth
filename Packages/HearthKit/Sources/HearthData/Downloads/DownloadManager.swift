import Foundation
import HearthAPI
import HearthModel
import Observation
import os
import SwiftData

/// Per-item observable download state.
@MainActor
@Observable
final class DownloadCell {
    var status: DownloadStatus
    var progress: Double

    init(status: DownloadStatus, progress: Double) {
        self.status = status
        self.progress = progress
    }
}

/// Downloads audiobooks/episodes (audio, PDFs, covers) with a background `URLSession` and manages automatic
/// downloads.
@MainActor
@Observable
public final class DownloadManager {
    static let maxConcurrentDownloads = 4
    static let maxRetries = 3
    /// 401 answers per asset (each after refreshing the token) before waiting for the next refresh / launch.
    static let maxAuthorizationRetries = 2
    nonisolated static let coverWeight = 10.0
    nonisolated static let pdfWeight = 10.0
    nonisolated static let audioWeight = 80.0

    static var sessionIdentifier: String {
        "\(Bundle.main.bundleIdentifier ?? "me.robinferch.hearth").downloads"
    }

    /// Bumped whenever the set of downloads changes (list queries observe it).
    private var revision = 0
    /// Bumped when auto-download rules or their items change.
    private var rulesRevision = 0
    /// Last completed automatic download run.
    public internal(set) var lastAutoDownloadRun: Date?

    @ObservationIgnored private var cells: [String: DownloadCell] = [:]
    @ObservationIgnored private var statuses: [String: DownloadStatus] = [:]
    @ObservationIgnored private var fractions: [String: Double] = [:]
    @ObservationIgnored private var items: [String: StoredItemValue] = [:]
    @ObservationIgnored private var assets: [String: [DownloadAsset]] = [:]
    @ObservationIgnored private var assetOwners: [String: String] = [:]
    @ObservationIgnored private var inflightFractions: [String: Double] = [:]
    @ObservationIgnored private var chapters: [String: [Chapter]] = [:]
    @ObservationIgnored private var locked = Set<String>()
    @ObservationIgnored private var pendingRemoval: [String: ItemIdentifier] = [:]
    @ObservationIgnored private var rules: [String: AutoDownloadRuleRecord] = [:]
    @ObservationIgnored private var tracked: [String: Set<ItemIdentifier>] = [:]
    @ObservationIgnored private var session: URLSession?
    /// Session callbacks, processed one after another by `eventsTask`.
    @ObservationIgnored private var events: AsyncStream<DownloadEvent>.Continuation?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundCompletions: [@Sendable () -> Void] = []
    /// `urlSessionDidFinishEvents` arrived and wasn't matched with a completion handler yet.
    @ObservationIgnored private var backgroundEventsDelivered = false
    /// Assets whose task is being created / runs in this process (prevents duplicate tasks).
    @ObservationIgnored private var startingAssets = Set<String>()
    @ObservationIgnored private var runningAssets = Set<String>()
    /// 401 answers per asset since the last success or resume.
    @ObservationIgnored private var authorizationRetries: [String: Int] = [:]
    /// Assets whose finished files may be moved into place (shared with the session delegate).
    @ObservationIgnored let activeAssets = ActiveDownloadAssets()
    /// Delay before retrying a failed asset; doubles with every further failure.
    @ObservationIgnored var retryBaseDelay: Duration
    @ObservationIgnored private var isRunningAutoDownloads = false

    @ObservationIgnored let environment: DataEnvironment
    @ObservationIgnored weak var hearth: HearthData?
    @ObservationIgnored private let logger = Logger(category: "DownloadManager")

    private static let lastRunKey = "downloads.lastAutoDownloadRun"

    init(environment: DataEnvironment) {
        self.environment = environment
        retryBaseDelay = environment.isLive ? .seconds(5) : .milliseconds(10)
        let context = ModelContext(environment.container)
        for value in context.storedItems(downloadedOnly: false) {
            items[value.item.id.storageKey] = value
        }
        for asset in context.assets() {
            let key = asset.itemID.storageKey
            assets[key, default: []].append(asset)
            assetOwners[asset.id] = key
            if !asset.isDownloaded {
                activeAssets.insert([asset.id])
            }
        }
        for (key, value) in items where value.item.id.isPlayable {
            if value.isDownloaded {
                statuses[key] = .completed
                chapters[key] = context.chapters(for: value.item.id)
            } else if assets[key] != nil {
                statuses[key] = .downloading
                fractions[key] = weightedProgress(key)
            }
        }
        for record in context.autoDownloadRules() {
            rules[record.key] = record
        }
        for record in context.autoDownloadedItems() {
            tracked[record.ruleKey, default: []].insert(record.itemID)
        }
        lastAutoDownloadRun = environment.defaults.object(forKey: Self.lastRunKey) as? Date
    }

    private var root: URL { environment.downloadsURL }

    // MARK: State

    private func cell(_ key: String) -> DownloadCell {
        if let cell = cells[key] {
            return cell
        }
        let cell = DownloadCell(status: statuses[key] ?? .none, progress: fractions[key] ?? (statuses[key] == .completed ? 1 : 0))
        cells[key] = cell
        return cell
    }

    private func setState(_ key: String, status: DownloadStatus, progress: Double? = nil) {
        statuses[key] = status == .none ? nil : status
        if status == .downloading {
            fractions[key] = progress ?? fractions[key] ?? 0
        } else {
            fractions[key] = nil
        }
        if let cell = cells[key] {
            if cell.status != status {
                cell.status = status
            }
            let value = status == .completed ? 1 : (fractions[key] ?? 0)
            if abs(cell.progress - value) > 0.001 || (status != .downloading && cell.progress != value) {
                cell.progress = value
            }
        }
    }

    public func status(of id: ItemIdentifier) -> DownloadStatus {
        cell(id.storageKey).status
    }

    /// 0...1 weighted progress while downloading.
    public func progress(of id: ItemIdentifier) -> Double {
        cell(id.storageKey).progress
    }

    /// Whether the item is currently locked (playing).
    public func isLocked(_ id: ItemIdentifier) -> Bool {
        locked.contains(id.storageKey)
    }

    private func weightedProgress(_ key: String) -> Double {
        let list = assets[key] ?? []
        let total = list.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return 0 }
        let done = list.reduce(0.0) { sum, asset in
            sum + asset.weight * (asset.isDownloaded ? 1 : (inflightFractions[asset.id] ?? 0))
        }
        return min(1, done / total)
    }

    private func refreshProgress(_ key: String) {
        guard statuses[key] == .downloading else { return }
        let value = weightedProgress(key)
        fractions[key] = value
        if let cell = cells[key], abs(cell.progress - value) >= 0.005 {
            cell.progress = value
        }
    }

    // MARK: Session

    private func downloadSession() -> URLSession {
        if let session {
            return session
        }
        // One ordered stream: a background completion handler must only run after the work for all earlier
        // callbacks is done (independent tasks per callback could run it first).
        let (stream, continuation) = AsyncStream<DownloadEvent>.makeStream()
        events = continuation
        eventsTask = Task { [weak self] in
            for await event in stream {
                await self?.handle(event)
            }
        }
        let delegate = DownloadSessionDelegate(root: root, trust: environment.trust, active: activeAssets, send: { continuation.yield($0) })
        let configuration: URLSessionConfiguration
        if environment.isLive {
            configuration = .background(withIdentifier: Self.sessionIdentifier)
            configuration.isDiscretionary = false
            #if !os(macOS)
            configuration.sessionSendsLaunchEvents = true
            #endif
        } else {
            configuration = .ephemeral
        }
        configuration.httpMaximumConnectionsPerHost = Self.maxConcurrentDownloads
        // Per-request flags restrict cellular / constrained access according to the user's setting.
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.session = session
        return session
    }

    /// Forwarded from `application(_:handleEventsForBackgroundURLSession:completionHandler:)` (iOS) or a
    /// `WKURLSessionRefreshBackgroundTask` (watchOS, possibly several). Every handler is called once the session
    /// delivered all events and their work is done.
    public func handleBackgroundEvents(identifier: String, completion: @escaping @Sendable () -> Void) {
        guard identifier == Self.sessionIdentifier else {
            completion()
            return
        }
        backgroundCompletions.append(completion)
        _ = downloadSession()
        if backgroundEventsDelivered {
            // The events arrived before the handler; finish after the work still queued.
            events?.yield(.drainBackgroundCompletions)
        }
    }

    /// Processes session callbacks in order.
    func handle(_ event: DownloadEvent) async {
        switch event {
        case .progress(let assetID, let written, let expected):
            await taskProgressed(assetID, written: written, expected: expected)
        case .finished(let assetID, let taskIdentifier, let result, let resumeData):
            await taskFinished(assetID, taskIdentifier: taskIdentifier, result: result, resumeData: resumeData)
        case .allEventsDelivered:
            backgroundEventsDelivered = true
            drainBackgroundCompletions()
        case .drainBackgroundCompletions:
            drainBackgroundCompletions()
        }
    }

    private func drainBackgroundCompletions() {
        guard backgroundEventsDelivered, !backgroundCompletions.isEmpty else { return }
        let completions = backgroundCompletions
        backgroundCompletions.removeAll()
        backgroundEventsDelivered = false
        for completion in completions {
            completion()
        }
    }

    private func applyNetworkPolicy(_ request: inout URLRequest) {
        let allowed = hearth?.settings.allowCellularDownloads ?? false
        request.allowsCellularAccess = allowed
        request.allowsExpensiveNetworkAccess = allowed
        request.allowsConstrainedNetworkAccess = allowed
    }

    private func request(for asset: DownloadAsset, client: any AudiobookshelfClient) async throws -> URLRequest {
        switch asset.kind {
        case .audio:
            return try await client.audioFileRequest(for: asset.itemID, ino: asset.ino ?? "")
        case .pdf:
            return try await client.pdfRequest(for: asset.itemID, ino: asset.ino ?? "")
        case .cover:
            return try await client.coverRequest(for: asset.itemID, size: asset.imageSize ?? .large)
        }
    }

    private func currentAsset(_ assetID: String) -> DownloadAsset? {
        assetOwners[assetID].flatMap { key in assets[key]?.first { $0.id == assetID } }
    }

    private func availableClient(for asset: DownloadAsset) -> (any AudiobookshelfClient)? {
        guard let hearth, hearth.connections.isAvailable(asset.itemID.connectionID) else { return nil }
        return try? hearth.connections.client(for: asset.itemID.connectionID)
    }

    /// Creates and resumes the task for an asset (no-op while its connection is unavailable, the asset was removed
    /// or a task for it is already being created or running).
    private func start(_ asset: DownloadAsset, resumeData: Data? = nil) async {
        let assetID = asset.id
        guard assetOwners[assetID] != nil, !startingAssets.contains(assetID), !runningAssets.contains(assetID), let client = availableClient(for: asset) else {
            return
        }
        // Marked before the first suspension so concurrent callers (resumePendingDownloads) skip it.
        startingAssets.insert(assetID)
        defer { startingAssets.remove(assetID) }

        let session = downloadSession()
        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            do {
                var request = try await request(for: asset, client: client)
                applyNetworkPolicy(&request)
                task = session.downloadTask(with: request)
            } catch {
                if (error as? APIError) != .invalidURL {
                    // Offline, unreachable, token refresh failed: not the asset's fault, resumed later.
                    logger.notice("Creating a download request failed, retrying later: \(String(describing: error), privacy: .public)")
                    return
                }
                logger.error("Creating a download request failed: \(String(describing: error), privacy: .public)")
                startingAssets.remove(assetID)
                await taskFinished(assetID, taskIdentifier: nil, result: .failure(error), resumeData: nil)
                return
            }
        }
        // The asset may have been removed while awaiting the request.
        guard let key = assetOwners[assetID], var list = assets[key], let index = list.firstIndex(where: { $0.id == assetID }) else {
            task.cancel()
            return
        }
        runningAssets.insert(assetID)
        task.taskDescription = DownloadTaskDescription(assetID: assetID, relativePath: asset.relativePath).encoded
        list[index].taskIdentifier = task.taskIdentifier
        assets[key] = list
        let updated = list[index]
        await environment.store.perform { $0.upsertAssets([updated]) }
        task.resume()
    }

    // MARK: Downloading

    public func download(_ id: ItemIdentifier) async throws {
        guard id.isPlayable else { throw DownloadError.notDownloadable }
        let key = id.storageKey
        if statuses[key] == .completed || statuses[key] == .downloading {
            return
        }
        guard let hearth else { throw APIError.offline }
        guard hearth.connections.isAvailable(id.connectionID), let client = try? hearth.connections.client(for: id.connectionID) else {
            throw APIError.offline
        }

        setState(key, status: .downloading, progress: 0)
        revision &+= 1
        do {
            let details = try await client.playableDetails(id)
            guard !details.audioFiles.isEmpty else { throw DownloadError.notDownloadable }
            let itemID = details.item.id
            let item = AnyItem(details.item)

            var fetchedPodcast: AnyItem?
            if let podcastID = itemID.podcastIdentifier, let result = try? await hearth.items.podcast(podcastID) {
                fetchedPodcast = .podcast(result.podcast)
            }
            let podcastItem = fetchedPodcast

            let list = Self.makeAssets(for: itemID, details: details)
            let chapterList = details.chapters
            await environment.store.perform { context in
                context.saveItem(item, downloaded: false)
                if let podcastItem {
                    context.saveItem(podcastItem, downloaded: true)
                }
                context.replaceChapters(chapterList, for: itemID)
                context.upsertAssets(list)
            }
            guard statuses[key] == .downloading else {
                // Cancelled while preparing.
                await removeNow(itemID)
                return
            }
            items[key] = StoredItemValue(item: item, isDownloaded: false)
            if let podcastItem {
                items[podcastItem.id.storageKey] = StoredItemValue(item: podcastItem, isDownloaded: true)
            }
            chapters[key] = chapterList
            assets[key] = list
            for asset in list {
                assetOwners[asset.id] = key
            }
            activeAssets.insert(list.map(\.id))
            hearth.items.remember([item])
            for asset in list {
                await start(asset)
            }
            refreshProgress(key)
        } catch {
            logger.error("Starting download of \(id.description, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            await removeNow(id)
            throw error
        }
    }

    public func download(_ ids: [ItemIdentifier]) async {
        for id in ids {
            do {
                try await download(id)
            } catch {
                logger.error("Download of \(id.description, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Asset list with weights: covers 10, PDFs 10, audio 80 (split by duration).
    nonisolated static func makeAssets(for id: ItemIdentifier, details: PlayableItemDetails) -> [DownloadAsset] {
        var list = [DownloadAsset]()
        let sizes = ImageSize.allCases
        for size in sizes {
            list.append(DownloadAsset(itemID: id, kind: .cover, relativePath: DownloadPaths.cover(id, size: size), imageSize: size, weight: coverWeight / Double(sizes.count)))
        }
        for pdf in details.pdfs {
            list.append(DownloadAsset(itemID: id, kind: .pdf, relativePath: DownloadPaths.pdf(id, ino: pdf.ino), ino: pdf.ino, weight: pdfWeight / Double(details.pdfs.count)))
        }
        let files = details.audioFiles.sorted { $0.offset < $1.offset }
        let totalDuration = files.reduce(0) { $0 + max(0, $1.duration) }
        for (index, file) in files.enumerated() {
            let share = totalDuration > 0 ? max(0, file.duration) / totalDuration : 1 / Double(files.count)
            list.append(DownloadAsset(itemID: id, kind: .audio, relativePath: DownloadPaths.audio(id, index: index, fileExtension: file.fileExtension), ino: file.ino, index: index, offset: file.offset, duration: file.duration, mimeType: file.mimeType, fileExtension: file.fileExtension, weight: audioWeight * share))
        }
        return list
    }

    private func taskProgressed(_ assetID: String, written: Int64, expected: Int64) async {
        guard let key = assetOwners[assetID], expected > 0 else { return }
        let isFirstReport = inflightFractions[assetID] == nil
        inflightFractions[assetID] = min(1, Double(written) / Double(expected))
        refreshProgress(key)
        if isFirstReport, var list = assets[key], let index = list.firstIndex(where: { $0.id == assetID }), list[index].failureCount > 0 {
            // Data flows again: earlier failures were transient and don't count towards giving up.
            list[index].failureCount = 0
            assets[key] = list
            let updated = list[index]
            await environment.store.perform { $0.upsertAssets([updated]) }
        }
    }

    enum FailureKind: Equatable {
        /// Cancelled by a removal, the system or a force quit; not the download's fault.
        case cancelled
        /// 401: refresh the token and try again.
        case unauthorized
        /// Retrying can't help (400, 403, 404, 410).
        case permanent
        case transient
    }

    nonisolated static func classify(_ error: any Error) -> FailureKind {
        switch error {
        case DownloadTaskError.unauthorized:
            .unauthorized
        case DownloadTaskError.httpStatus(let status) where [400, 403, 404, 410].contains(status):
            .permanent
        case DownloadTaskError.discarded, APIError.cancelled:
            .cancelled
        case let error as URLError where error.code == .cancelled:
            .cancelled
        default:
            .transient
        }
    }

    /// - Parameter taskIdentifier: the finished task (`nil` if no task could be created).
    private func taskFinished(_ assetID: String, taskIdentifier: Int?, result: Result<Int64, any Error>, resumeData: Data?) async {
        guard let key = assetOwners[assetID], var list = assets[key], let index = list.firstIndex(where: { $0.id == assetID }) else {
            inflightFractions[assetID] = nil
            return
        }
        if let taskIdentifier, let current = list[index].taskIdentifier, current != taskIdentifier {
            // A replaced task (e.g. cancelled by a force quit, reported after the asset was restarted).
            logger.notice("Ignoring completion of a replaced download task")
            return
        }
        inflightFractions[assetID] = nil
        runningAssets.remove(assetID)
        var asset = list[index]
        asset.taskIdentifier = nil
        switch result {
        case .success(let bytes):
            asset.isDownloaded = true
            asset.byteCount = bytes
            list[index] = asset
            assets[key] = list
            authorizationRetries[assetID] = nil
            let updated = asset
            await environment.store.perform { $0.upsertAssets([updated]) }
            await checkCompletion(key)
        case .failure(let error):
            let kind = Self.classify(error)
            switch kind {
            case .cancelled:
                // Removals are handled above (the asset is gone).
                guard statuses[key] == .downloading else { return }
                logger.notice("Download task was cancelled, resuming")
                await save(asset, at: index, in: key)
                // Delayed (without counting a failure) so repeated system cancellations can't spin.
                scheduleRetry(asset, resumeData: resumeData)
            case .unauthorized:
                let retries = (authorizationRetries[assetID] ?? 0) + 1
                authorizationRetries[assetID] = retries
                await save(asset, at: index, in: key)
                guard retries <= Self.maxAuthorizationRetries, let client = availableClient(for: asset) else {
                    logger.error("Download rejected with 401 again; retrying after the next refresh")
                    return
                }
                if case DownloadTaskError.unauthorized(let request?) = error {
                    // Throws (and marks the connection unauthorized) if the user must sign in again; `start` is a
                    // no-op then.
                    try? await client.refreshAuthorization(rejectedRequest: request)
                }
                await start(asset)
            case .permanent, .transient:
                asset.failureCount = kind == .permanent ? Self.maxRetries + 1 : asset.failureCount + 1
                logger.error("Download task failed (\(asset.failureCount)): \(String(describing: error), privacy: .public)")
                if asset.failureCount > Self.maxRetries {
                    if asset.kind == .audio {
                        logger.error("Giving up on \(asset.itemID.description, privacy: .public)")
                        await removeNow(asset.itemID)
                    } else {
                        // Covers and PDFs are optional.
                        list.remove(at: index)
                        assets[key] = list
                        assetOwners[assetID] = nil
                        activeAssets.remove([assetID])
                        await environment.store.perform { $0.deleteAsset(id: assetID) }
                        await checkCompletion(key)
                    }
                } else {
                    await save(asset, at: index, in: key)
                    scheduleRetry(asset, resumeData: resumeData)
                }
            }
        }
        refreshProgress(key)
    }

    private func save(_ asset: DownloadAsset, at index: Int, in key: String) async {
        guard var list = assets[key], list.indices.contains(index), list[index].id == asset.id else { return }
        list[index] = asset
        assets[key] = list
        await environment.store.perform { $0.upsertAssets([asset]) }
    }

    /// Restarts an asset after a delay that doubles with every counted failure.
    private func scheduleRetry(_ asset: DownloadAsset, resumeData: Data?) {
        let delay = retryBaseDelay * (1 << min(max(asset.failureCount - 1, 0), 6))
        let assetID = asset.id
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, let current = self.currentAsset(assetID), !current.isDownloaded else { return }
            await self.start(current, resumeData: resumeData)
        }
    }

    private func checkCompletion(_ key: String) async {
        guard statuses[key] == .downloading, let list = assets[key], !list.isEmpty, list.allSatisfy(\.isDownloaded), list.contains(where: { $0.kind == .audio }) else {
            return
        }
        guard let value = items[key] else { return }
        let id = value.item.id
        items[key]?.isDownloaded = true
        items[key]?.downloadCompletedAt = .now
        await environment.store.perform { $0.setItemDownloaded(id, downloaded: true) }
        setState(key, status: .completed)
        revision &+= 1
        logger.info("Download of \(id.description, privacy: .public) completed")
        hearth?.downloadsChanged()
    }

    /// Recreates tasks for unfinished assets (after launch, reconnecting or a crash).
    func resumePendingDownloads() async {
        let pending = assets.values.flatMap { $0 }.filter { !$0.isDownloaded }
        guard !pending.isEmpty else { return }
        let session = downloadSession()
        let tasks = await session.allTasks
        let live = Set(tasks.compactMap { DownloadTaskDescription($0.taskDescription)?.assetID })
        for asset in pending where !live.contains(asset.id) {
            authorizationRetries[asset.id] = nil
            // Skips assets removed meanwhile and assets whose task is being created or running (`download`).
            await start(asset)
        }
    }

    // MARK: Removing

    /// Removes a download. Passing a podcast removes all of its downloaded episodes.
    public func remove(_ id: ItemIdentifier) async {
        if id.kind == .podcast {
            let episodes = items.values.map(\.item.id).filter { $0.kind == .episode && $0.connectionID == id.connectionID && $0.groupingID == id.primaryID }
            for episode in episodes {
                await remove(episode)
            }
            return
        }
        let key = id.storageKey
        if locked.contains(key) {
            logger.notice("\(id.description, privacy: .public) is playing; removing after playback")
            pendingRemoval[key] = id
            return
        }
        await removeNow(id)
    }

    public func cancel(_ id: ItemIdentifier) async {
        await removeNow(id)
    }

    public func removeAll() async {
        for value in items.values where value.item.id.isPlayable && !locked.contains(value.item.id.storageKey) {
            await removeNow(value.item.id)
        }
    }

    /// Removes every download of a connection (connection removal; ignores locks).
    func removeAll(connection: ConnectionID) async {
        for value in items.values where value.item.id.connectionID == connection && value.item.id.isPlayable {
            await removeNow(value.item.id)
        }
        let leftovers = items.keys.filter { items[$0]?.item.id.connectionID == connection }
        for key in leftovers {
            items[key] = nil
        }
        try? FileManager.default.removeItem(at: root.appending(path: connection, directoryHint: .isDirectory))
        for key in rules.keys where rules[key]?.grouping?.connectionID == connection {
            rules[key] = nil
            tracked[key] = nil
        }
        for key in tracked.keys {
            tracked[key] = tracked[key]?.filter { $0.connectionID != connection }
        }
        rulesRevision &+= 1
        revision &+= 1
    }

    private func removeNow(_ requested: ItemIdentifier) async {
        let key = requested.storageKey
        let id = items[key]?.item.id ?? requested
        let assetIDs = Set((assets[key] ?? []).map(\.id))
        // First, so tasks finishing from now on don't move files into the directory deleted below.
        activeAssets.remove(assetIDs)
        runningAssets.subtract(assetIDs)

        if let session, !assetIDs.isEmpty {
            for task in await session.allTasks where assetIDs.contains(DownloadTaskDescription(task.taskDescription)?.assetID ?? "") {
                task.cancel()
            }
        }
        for assetID in assetIDs {
            assetOwners[assetID] = nil
            inflightFractions[assetID] = nil
            authorizationRetries[assetID] = nil
        }
        assets[key] = nil
        chapters[key] = nil
        items[key] = nil
        pendingRemoval[key] = nil
        setState(key, status: .none)

        try? FileManager.default.removeItem(at: root.appending(path: DownloadPaths.directory(for: id), directoryHint: .isDirectory))
        var podcastToRemove: ItemIdentifier?
        if let podcastID = id.podcastIdentifier {
            let remaining = items.values.contains { value in
                value.item.id.kind == .episode && value.item.id.connectionID == id.connectionID && value.item.id.groupingID == podcastID.primaryID
            }
            if !remaining {
                podcastToRemove = items[podcastID.storageKey]?.item.id ?? podcastID
                items[podcastID.storageKey] = nil
            }
        }
        let removedPodcast = podcastToRemove
        await environment.store.perform { context in
            context.deleteAssets(for: id)
            context.deleteItem(id)
            context.removeAutoDownloadedItem(id, ruleKey: nil)
            if let removedPodcast {
                context.deleteItem(removedPodcast)
            }
        }
        var trackingChanged = false
        for ruleKey in tracked.keys where tracked[ruleKey]?.contains(id) == true {
            tracked[ruleKey]?.remove(id)
            trackingChanged = true
        }
        if trackingChanged {
            rulesRevision &+= 1
        }
        revision &+= 1
        hearth?.downloadsChanged()
    }

    // MARK: Locking

    /// Locks an item while it plays so it can't be removed.
    public func lock(_ id: ItemIdentifier) {
        locked.insert(id.storageKey)
    }

    public func unlock(_ id: ItemIdentifier) {
        let key = id.storageKey
        locked.remove(key)
        if let pending = pendingRemoval.removeValue(forKey: key) {
            Task { await removeNow(pending) }
        }
    }

    // MARK: Queries

    private var completedItems: [AnyItem] {
        _ = revision
        return items.compactMap { key, value in statuses[key] == .completed ? value.item : nil }
    }

    public func downloadedAudiobooks(in library: LibraryIdentifier? = nil) -> [Audiobook] {
        completedItems
            .compactMap { if case .audiobook(let audiobook) = $0 { audiobook } else { nil } }
            .filter { library == nil || $0.id.library == library }
            .sorted { $0.sortName < $1.sortName }
    }

    public func downloadedPodcasts(in library: LibraryIdentifier? = nil) -> [Podcast] {
        let episodes = downloadedEpisodes()
        let podcastKeys = Set(episodes.compactMap { $0.id.podcastIdentifier?.storageKey })
        return items.values
            .compactMap { value -> Podcast? in
                guard case .podcast(let podcast) = value.item, podcastKeys.contains(podcast.id.storageKey) else { return nil }
                return podcast
            }
            .filter { library == nil || $0.id.library == library }
            .sorted { $0.sortName < $1.sortName }
    }

    public func downloadedEpisodes(podcast: ItemIdentifier? = nil) -> [Episode] {
        completedItems
            .compactMap { if case .episode(let episode) = $0 { episode } else { nil } }
            .filter { podcast == nil || ($0.id.connectionID == podcast?.connectionID && $0.id.groupingID == podcast?.primaryID) }
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
    }

    /// Downloaded or downloading item identifiers.
    func presentItems() -> Set<ItemIdentifier> {
        Set(items.compactMap { key, value in statuses[key] != nil ? value.item.id : nil })
    }

    public func localPlayback(for id: ItemIdentifier) -> LocalPlaybackInfo? {
        let key = id.storageKey
        guard statuses[key] == .completed, let list = assets[key] else { return nil }
        let tracks = list.filter { $0.kind == .audio && $0.isDownloaded }
            .sorted { $0.index < $1.index }
            .map { AudioTrack(index: $0.index, offset: $0.offset, duration: $0.duration, url: root.appending(path: $0.relativePath), mimeType: $0.mimeType) }
        guard !tracks.isEmpty else { return nil }
        return LocalPlaybackInfo(tracks: tracks, chapters: chapters[key] ?? [])
    }

    /// Details reconstructed from the download (offline playback, detail screens).
    func offlineDetails(for id: ItemIdentifier) async -> PlayableItemDetails? {
        let key = id.storageKey
        guard statuses[key] == .completed, let item = items[key]?.item.playable, let list = assets[key] else { return nil }
        let audioFiles = list.filter { $0.kind == .audio }.sorted { $0.index < $1.index }.map {
            AudioFile(ino: $0.ino ?? "", fileExtension: $0.fileExtension ?? "", offset: $0.offset, duration: $0.duration, mimeType: $0.mimeType)
        }
        let downloadedPDFs = Set(list.filter { $0.kind == .pdf && $0.isDownloaded }.compactMap(\.ino))
        let pdfs: [PDFFile]
        if case .audiobook(let audiobook) = item {
            pdfs = audiobook.pdfs.filter { downloadedPDFs.contains($0.ino) }
        } else {
            pdfs = []
        }
        return PlayableItemDetails(item: item, audioFiles: audioFiles, chapters: chapters[key] ?? [], pdfs: pdfs, progress: hearth?.progress.peek(id))
    }

    public func localCoverURL(for id: ItemIdentifier) -> URL? {
        localCoverURL(for: id, size: .large)
    }

    /// Smallest downloaded cover at least `size` wide, else the largest available. Podcasts use an episode's cover.
    public func localCoverURL(for id: ItemIdentifier, size: ImageSize) -> URL? {
        var covers = (assets[id.storageKey] ?? []).filter { $0.kind == .cover && $0.isDownloaded }
        if covers.isEmpty, id.kind == .podcast {
            covers = assets.values.first { list in
                list.first?.itemID.connectionID == id.connectionID && list.first?.itemID.groupingID == id.primaryID && list.contains { $0.kind == .cover && $0.isDownloaded }
            }?.filter { $0.kind == .cover && $0.isDownloaded } ?? []
        }
        let sorted = covers.sorted { ($0.imageSize ?? .tiny) < ($1.imageSize ?? .tiny) }
        let match = sorted.first { ($0.imageSize ?? .tiny) >= size } ?? sorted.last
        return match.map { root.appending(path: $0.relativePath) }
    }

    public func localPDFURL(for id: ItemIdentifier, ino: String) -> URL? {
        guard let asset = assets[id.storageKey]?.first(where: { $0.kind == .pdf && $0.ino == ino && $0.isDownloaded }) else { return nil }
        return root.appending(path: asset.relativePath)
    }

    public func storageUsed() async -> Int64 {
        let root = root
        return await Task.detached(priority: .utility) { FileSystem.size(of: root) }.value
    }

    // MARK: Automatic downloads

    public func autoDownloadRule(for grouping: ItemIdentifier) -> AutoDownloadRule {
        _ = rulesRevision
        return rules[grouping.storageKey]?.rule ?? .disabled
    }

    public func setAutoDownloadRule(_ rule: AutoDownloadRule, for grouping: ItemIdentifier) async {
        let record = AutoDownloadRuleRecord(grouping: grouping, rule: rule)
        rules[record.key] = rule == .disabled ? nil : record
        rulesRevision &+= 1
        await environment.store.perform { $0.setAutoDownloadRule(record) }
        if rule == .disabled {
            await applyAutoDownloads(desired: [record.key: []])
            tracked[record.key] = nil
            await environment.store.perform { $0.removeAutoDownloadedItems(ruleKey: record.key) }
        } else {
            await runAutoDownloads(only: [record.key])
        }
    }

    /// Groupings that have a rule configured.
    public func autoDownloadConfigurations() -> [(grouping: ItemIdentifier, rule: AutoDownloadRule)] {
        _ = rulesRevision
        return rules.values
            .compactMap { record in record.grouping.map { (grouping: $0, rule: record.rule) } }
            .sorted { $0.grouping.description < $1.grouping.description }
    }

    public func isAutomaticallyDownloaded(_ id: ItemIdentifier) -> Bool {
        _ = rulesRevision
        return tracked.values.contains { $0.contains(id) }
    }

    /// Evaluates all rules; called from background refresh, after finishing items, after Listen Now changes.
    public func runAutoDownloads() async {
        await runAutoDownloads(only: nil)
    }

    private func runAutoDownloads(only ruleKeys: Set<String>?) async {
        guard let hearth, hearth.settings.autoDownloadsEnabled, !hearth.connections.isOffline, !isRunningAutoDownloads else { return }
        isRunningAutoDownloads = true
        defer { isRunningAutoDownloads = false }

        var desired = [String: [ItemIdentifier]]()
        for record in rules.values where ruleKeys?.contains(record.key) ?? true {
            guard let grouping = record.grouping, hearth.connections.isAvailable(grouping.connectionID) else { continue }
            if let candidates = await candidates(for: grouping) {
                desired[record.key] = AutoDownloadPlanner.select(record.rule, candidates: candidates)
            }
        }
        if ruleKeys == nil {
            if hearth.settings.autoDownloadListenNow {
                let listenNow = await hearth.items.listenNow()
                desired[AutoDownloadRuleKey.listenNow] = listenNow.map(\.id)
            } else if tracked[AutoDownloadRuleKey.listenNow]?.isEmpty == false {
                desired[AutoDownloadRuleKey.listenNow] = []
            }
        }
        await applyAutoDownloads(desired: desired)

        if ruleKeys == nil {
            lastAutoDownloadRun = .now
            environment.defaults.set(lastAutoDownloadRun, forKey: Self.lastRunKey)
        }
    }

    private func applyAutoDownloads(desired: [String: [ItemIdentifier]]) async {
        guard let hearth else { return }
        let finished = Set(hearth.progress.all().filter(\.isFinished).map(\.itemID))
        let present = presentItems()
        let changes = AutoDownloadPlanner.reconcile(
            desired: desired,
            tracked: tracked,
            present: present,
            locked: Set(present.filter { locked.contains($0.storageKey) }),
            finished: Set(present.filter { item in finished.contains { $0.storageKey == item.storageKey } }),
            removeFinished: hearth.settings.removeFinishedDownloads
        )

        for pair in changes.untrack {
            tracked[pair.ruleKey]?.remove(pair.itemID)
        }
        for pair in changes.track {
            tracked[pair.ruleKey, default: []].insert(pair.itemID)
        }
        if !changes.track.isEmpty || !changes.untrack.isEmpty {
            rulesRevision &+= 1
            let track = changes.track
            let untrack = changes.untrack
            await environment.store.perform { context in
                for pair in untrack {
                    context.removeAutoDownloadedItem(pair.itemID, ruleKey: pair.ruleKey)
                }
                for pair in track {
                    context.addAutoDownloadedItem(pair.itemID, ruleKey: pair.ruleKey)
                }
            }
        }
        for id in changes.remove {
            await remove(id)
        }
        for id in changes.download {
            do {
                try await download(id)
            } catch {
                logger.error("Automatic download of \(id.description, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                for ruleKey in tracked.keys where tracked[ruleKey]?.contains(id) == true {
                    tracked[ruleKey]?.remove(id)
                }
                await environment.store.perform { $0.removeAutoDownloadedItem(id, ruleKey: nil) }
                rulesRevision &+= 1
            }
        }
    }

    /// Ordered candidates of a grouping, or `nil` when they couldn't be loaded (the rule is then skipped).
    private func candidates(for grouping: ItemIdentifier) async -> [AutoDownloadPlanner.Candidate]? {
        guard let hearth else { return nil }
        let isFinished: (ItemIdentifier) -> Bool = { hearth.progress.peek($0)?.isFinished ?? false }
        switch grouping.kind {
        case .series:
            let books = await hearth.items.seriesBooks(grouping)
            guard !books.isEmpty else { return nil }
            return books.map { AutoDownloadPlanner.Candidate(id: $0.id, isFinished: isFinished($0.id), released: $0.addedAt) }
        case .podcast:
            guard let result = try? await hearth.items.podcast(grouping) else { return nil }
            let settings = hearth.itemSettings.episodeListSettings(for: result.podcast)
            return EpisodeListing.sort(result.episodes, by: settings.sort, direction: settings.direction).map {
                AutoDownloadPlanner.Candidate(id: $0.id, isFinished: isFinished($0.id), released: $0.publishedAt ?? $0.addedAt)
            }
        case .collection, .playlist:
            guard case .collection(let collection)? = try? await hearth.items.item(grouping) else { return nil }
            return collection.items.map { AutoDownloadPlanner.Candidate(id: $0.id, isFinished: isFinished($0.id), released: $0.releaseDate) }
        default:
            return nil
        }
    }

    /// Called when an item finished playing (removes download if configured, schedules follow-ups).
    public func itemFinished(_ id: ItemIdentifier) async {
        if hearth?.settings.removeFinishedDownloads == true, statuses[id.storageKey] == .completed {
            await remove(id)
        }
        await runAutoDownloads()
    }
}
