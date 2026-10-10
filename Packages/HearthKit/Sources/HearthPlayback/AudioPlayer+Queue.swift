import Foundation
import HearthData
import HearthModel

/// Queue, Up Next and the item-finished flow (spec §2).
extension AudioPlayer {
    // MARK: Enqueueing

    func enqueue(_ id: ItemIdentifier, atFront: Bool) async throws {
        guard id.isPlayable else { throw PlaybackError.notPlayable }
        if currentItem == nil {
            try await startPlayback(id, origin: .none, at: nil, resetUpNext: true)
            return
        }
        guard !isCurrent(id) else { return }
        let item: AnyPlayableItem
        do {
            item = try await HearthData.shared.items.playable(id)
        } catch {
            throw PlaybackError.startFailed(error.localizedDescription)
        }
        queue = atFront ? QueueLogic.insertingFront(item, into: queue) : QueueLogic.appending(item, to: queue)
        upNext.removeAll { $0.id == id }
        queueDidChange()
    }

    func enqueue(_ ids: [ItemIdentifier]) async {
        for id in ids where id.isPlayable {
            do {
                try await enqueue(id, atFront: false)
            } catch {
                logger.error("Adding \(id, privacy: .public) to the queue failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func queueDidChange() {
        if queueRestored {
            PlaybackPersistence.queue = queue.map(\.id)
        }
        updateNowPlayingInfo()
        updateRemoteCommandAvailability()
    }

    /// Restores the persisted queue once connections are loaded.
    func restoreQueue() {
        let ids = PlaybackPersistence.queue
        guard !ids.isEmpty else {
            queueRestored = true
            return
        }
        Task {
            let data = HearthData.shared
            var attempts = 0
            while !data.connections.isLoaded, attempts < 100 {
                attempts += 1
                try? await Task.sleep(for: .milliseconds(200))
            }
            var restored: [AnyPlayableItem] = []
            for id in ids {
                if let item = try? await data.items.playable(id) {
                    restored.append(item)
                }
            }
            let excluded: Set<ItemIdentifier> = currentItem.map { [$0.id] } ?? []
            queue = QueueLogic.pruned(restored + queue, excluding: excluded) { data.progress.progress(for: $0)?.isFinished == true }
            queueRestored = true
            queueDidChange()
        }
    }

    /// Removes finished items (and `id`) from both tiers.
    func pruneFinishedItems(also id: ItemIdentifier? = nil) {
        let progress = HearthData.shared.progress
        var excluded: Set<ItemIdentifier> = []
        if let id {
            excluded.insert(id)
        }
        if let current = currentItem {
            excluded.insert(current.id)
        }
        queue = QueueLogic.pruned(queue, excluding: excluded) { progress.progress(for: $0)?.isFinished == true }
        upNext = QueueLogic.pruned(upNext, excluding: excluded.union(queue.map(\.id))) { progress.progress(for: $0)?.isFinished == true }
        if upNext.isEmpty {
            upNextSource = nil
        }
        queueDidChange()
    }

    // MARK: Jumping & advancing

    func performJumpToQueueItem(at index: Int) async {
        guard let (item, remaining) = QueueLogic.take(queue, at: index) else { return }
        queue = remaining
        queueDidChange()
        await start(item, origin: .none)
    }

    func performJumpToUpNextItem(at index: Int) async {
        guard let (item, remaining) = QueueLogic.take(upNext, at: index) else { return }
        queue = []
        upNext = remaining
        queueDidChange()
        await start(item, origin: origin)
    }

    func performAdvance() async {
        guard currentItem != nil else { return }
        if await startNextInLine() == false {
            await performStop()
        }
    }

    private func start(_ item: AnyPlayableItem, origin: PlaybackOrigin) async {
        do {
            try await startPlayback(item.id, origin: origin, at: nil, resetUpNext: false)
        } catch is CancellationError {
            return
        } catch {
            logger.error("Starting \(item.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Starts the first queue item, else the first Up Next item. Returns `false` when nothing is left.
    func startNextInLine() async -> Bool {
        while true {
            let next: AnyPlayableItem
            let nextOrigin: PlaybackOrigin
            if !queue.isEmpty {
                next = queue.removeFirst()
                nextOrigin = .none
            } else if !upNext.isEmpty {
                next = upNext.removeFirst()
                nextOrigin = origin
            } else {
                return false
            }
            queueDidChange()
            do {
                try await startPlayback(next.id, origin: nextOrigin, at: nil, resetUpNext: false)
                return true
            } catch is CancellationError {
                return true
            } catch {
                logger.error("Starting next item \(next.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Natural finish

    /// Item reached its end (or was seeked past it / marked finished while playing).
    func handleItemFinished() async {
        guard let item = currentItem, finishingRunID != runID else { return }
        finishingRunID = runID
        let id = item.id

        // The item end is a chapter boundary for chapter sleep timers.
        var stopAfterwards = false
        if case .chapters(let remaining, let original)? = sleepTimer {
            if remaining <= 1 {
                stopAfterwards = true
            } else {
                sleepTimer = .chapters(remaining: remaining - 1, original: original)
                sleepTimerDidChange(expired: false)
            }
        }

        currentTime = duration
        finalizeCurrentRun(finished: true) {
            // Auto-download hook (delete if configured, schedule next downloads) after progress is final.
            await HearthData.shared.downloads.itemFinished(id)
        }
        post(Self.itemFinishedNotification, itemID: id)

        if lastPlayedItemID == id {
            lastPlayedItemID = nil
            PlaybackPersistence.lastPlayedItemID = nil
            PlaybackPersistence.lastPlayedOrigin = nil
        }
        pruneFinishedItems(also: id)

        if stopAfterwards {
            expireSleepTimer(pausePlayback: false)
            // Don't start the next item while the listener sleeps, but make it the "Resume" target.
            let nextOrigin = queue.isEmpty ? origin : .none
            if let next = queue.first ?? upNext.first {
                queue.removeAll { $0.id == next.id }
                lastPlayedItemID = next.id
                PlaybackPersistence.lastPlayedItemID = next.id
                PlaybackPersistence.lastPlayedOrigin = nextOrigin
                queueDidChange()
            }
            runID = UUID()
            resetToIdle()
            return
        }

        if await startNextInLine() == false {
            performCancelSleepTimer()
            runID = UUID()
            resetToIdle()
        }
    }

    // MARK: Up Next generation

    func generateUpNextIfNeeded() async {
        guard let item = currentItem, upNext.isEmpty, !upNextGenerationDisabled, AppSettings.shared.generateUpNext else { return }
        let run = runID
        let result = await upNextCandidates(for: item, origin: origin)
        guard run == runID, upNext.isEmpty, !upNextGenerationDisabled else { return }
        let progress = HearthData.shared.progress
        let excluded = Set([item.id] + queue.map(\.id))
        upNext = QueueLogic.pruned(result.items, excluding: excluded) { progress.progress(for: $0)?.isFinished == true }
        upNextSource = upNext.isEmpty ? nil : result.source
        queueDidChange()
    }

    /// Origin (series/podcast/collection screen) > podcast strategy > series strategy.
    func upNextCandidates(for item: AnyPlayableItem, origin: PlaybackOrigin) async -> (items: [AnyPlayableItem], source: String?) {
        let data = HearthData.shared
        var groupings: [PlaybackOrigin] = []
        switch origin {
        case .series, .podcast, .collection:
            groupings.append(origin)
        case .listenNow:
            let items = await data.items.listenNow()
            if !items.isEmpty {
                return (items, String(localized: "Listen Now"))
            }
        case .none, .carPlay:
            break
        }
        if let podcast = item.id.podcastIdentifier, !groupings.contains(.podcast(podcast)) {
            groupings.append(.podcast(podcast))
        }
        if case .audiobook(let audiobook) = item, let seriesID = audiobook.series.first(where: { $0.id != nil })?.id {
            let series = ItemIdentifier(kind: .series, connectionID: audiobook.id.connectionID, libraryID: audiobook.id.libraryID, primaryID: seriesID)
            if !groupings.contains(.series(series)) {
                groupings.append(.series(series))
            }
        }

        for grouping in groupings {
            guard let groupingID = grouping.groupingID else { continue }
            switch data.itemSettings.upNextStrategy(for: groupingID) {
            case .disabled:
                return ([], nil)
            case .listenNow:
                let items = await data.items.listenNow()
                if !items.isEmpty {
                    return (items, String(localized: "Listen Now"))
                }
            case .default:
                let items = await data.items.upNext(after: item.id, origin: grouping)
                if !items.isEmpty {
                    return (items, await upNextSourceName(for: grouping, item: item))
                }
            }
        }
        return ([], nil)
    }

    func upNextSourceName(for grouping: PlaybackOrigin, item: AnyPlayableItem) async -> String? {
        let data = HearthData.shared
        switch grouping {
        case .series(let id):
            var name: String?
            if case .audiobook(let audiobook) = item {
                name = audiobook.series.first { $0.id == id.primaryID }?.name
            }
            if name == nil {
                name = try? await data.items.item(id).name
            }
            return name.map { String(localized: "Series: \($0)") }
        case .podcast(let id):
            var name: String?
            if case .episode(let episode) = item {
                name = episode.podcastName
            }
            if name == nil {
                name = try? await data.items.item(id).name
            }
            return name.map { String(localized: "Podcast: \($0)") }
        case .collection(let id):
            guard let name = try? await data.items.item(id).name else { return nil }
            return id.kind == .playlist ? String(localized: "Playlist: \(name)") : String(localized: "Collection: \(name)")
        case .listenNow:
            return String(localized: "Listen Now")
        case .none, .carPlay:
            return nil
        }
    }
}
