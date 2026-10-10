import Foundation
import HearthModel

// MARK: - Listen Now

enum ListenNowPlanner {
    static let defaultLimit = 30

    /// In-progress, visible, playable items of known connections, newest first (offline: downloaded only).
    static func order(_ progress: [ProgressEntity], connections: Set<ConnectionID>, offline: Bool, isDownloaded: (ItemIdentifier) -> Bool, limit: Int = defaultLimit) -> [ItemIdentifier] {
        var seen = Set<String>()
        return progress
            .filter { $0.isInProgress && !$0.hideFromContinueListening && connections.contains($0.itemID.connectionID) }
            .filter { $0.itemID.kind.isPlayable }
            .filter { !offline || isDownloaded($0.itemID) }
            .sorted { $0.lastUpdate > $1.lastUpdate }
            .map(\.itemID)
            .filter { seen.insert($0.storageKey).inserted }
            .prefix(limit)
            .map { $0 }
    }
}

// MARK: - Up Next

enum UpNextSource: Hashable, Sendable {
    case none
    case series(ItemIdentifier)
    case podcast(ItemIdentifier)
    case collection(ItemIdentifier)
    case listenNow
}

enum UpNextPlanner {
    /// Resolves which source generates Up Next: origin grouping > podcast > series, honouring per-grouping strategies.
    static func source(origin: PlaybackOrigin, item: AnyPlayableItem, strategy: (ItemIdentifier) -> UpNextStrategy) -> UpNextSource {
        func resolve(_ grouping: ItemIdentifier, _ source: UpNextSource) -> UpNextSource {
            switch strategy(grouping) {
            case .default: source
            case .listenNow: .listenNow
            case .disabled: .none
            }
        }

        switch origin {
        case .series(let id):
            return resolve(id, .series(id))
        case .podcast(let id):
            return resolve(id, .podcast(id))
        case .collection(let id):
            return resolve(id, .collection(id))
        case .listenNow:
            return .listenNow
        case .none, .carPlay:
            switch item {
            case .episode(let episode):
                guard let podcast = episode.id.podcastIdentifier else { return .none }
                return resolve(podcast, .podcast(podcast))
            case .audiobook(let audiobook):
                guard let seriesID = audiobook.series.first(where: { $0.id != nil })?.id else { return .none }
                let series = ItemIdentifier(kind: .series, connectionID: audiobook.id.connectionID, libraryID: audiobook.id.libraryID, primaryID: seriesID)
                return resolve(series, .series(series))
            }
        }
    }

    /// Unfinished items after `current` (all unfinished items when `current` isn't part of the list).
    static func following(_ current: ItemIdentifier, in ordered: [AnyPlayableItem], isFinished: (ItemIdentifier) -> Bool) -> [AnyPlayableItem] {
        let start = ordered.firstIndex { $0.id.storageKey == current.storageKey }.map { $0 + 1 } ?? 0
        return ordered[start...].filter { $0.id.storageKey != current.storageKey && !isFinished($0.id) }
    }

    /// Unfinished items other than `current`, keeping order (podcasts: the saved episode order).
    static func excluding(_ current: ItemIdentifier, from ordered: [AnyPlayableItem], isFinished: (ItemIdentifier) -> Bool) -> [AnyPlayableItem] {
        ordered.filter { $0.id.storageKey != current.storageKey && !isFinished($0.id) }
    }

    /// First unfinished item, falling back to the first one.
    static func firstUnfinished(in ordered: [AnyPlayableItem], isFinished: (ItemIdentifier) -> Bool) -> AnyPlayableItem? {
        ordered.first { !isFinished($0.id) } ?? ordered.first
    }
}

// MARK: - Auto downloads

enum AutoDownloadPlanner {
    struct Candidate: Sendable, Hashable {
        var id: ItemIdentifier
        var isFinished: Bool
        var released: Date?
    }

    /// Items a rule wants downloaded, in candidate order. Finished items are never selected.
    static func select(_ rule: AutoDownloadRule, candidates: [Candidate], now: Date = .now) -> [ItemIdentifier] {
        let unfinished = candidates.filter { !$0.isFinished }
        switch rule {
        case .disabled:
            return []
        case .all:
            return unfinished.map(\.id)
        case .nextUnfinished(let count):
            return unfinished.prefix(max(0, count)).map(\.id)
        case .releasedWithin(let hours):
            let threshold = now.addingTimeInterval(-Double(hours) * 3600)
            return unfinished.filter { ($0.released ?? .distantPast) >= threshold }.map(\.id)
        }
    }

    struct Changes: Sendable, Equatable {
        /// Items to start downloading (deduplicated, in rule order).
        var download: [ItemIdentifier] = []
        /// Downloads to delete.
        var remove: [ItemIdentifier] = []
        /// (rule key, item) pairs to record.
        var track: [Pair] = []
        /// (rule key, item) pairs to forget.
        var untrack: [Pair] = []
    }

    struct Pair: Sendable, Hashable {
        var ruleKey: String
        var itemID: ItemIdentifier
    }

    /// Computes download/removal work after evaluating some rules.
    ///
    /// - Parameters:
    ///   - desired: rule key → wanted items, for the rules that were evaluated successfully.
    ///   - tracked: rule key → items that rule downloaded earlier (all rules).
    ///   - present: items downloaded or downloading.
    ///   - locked: items that must not be removed now (playing).
    ///   - finished: finished items.
    ///   - removeFinished: whether finished items may be deleted.
    static func reconcile(desired: [String: [ItemIdentifier]], tracked: [String: Set<ItemIdentifier>], present: Set<ItemIdentifier>, locked: Set<ItemIdentifier>, finished: Set<ItemIdentifier>, removeFinished: Bool) -> Changes {
        var changes = Changes()
        var downloadSeen = Set<ItemIdentifier>()
        let trackedAnywhere = Set(tracked.values.flatMap { $0 })
        var remainingTracked = tracked

        for (ruleKey, items) in desired.sorted(by: { $0.key < $1.key }) {
            let wanted = Set(items)
            for item in items {
                let alreadyTracked = tracked[ruleKey]?.contains(item) ?? false
                if !present.contains(item) {
                    if downloadSeen.insert(item).inserted {
                        changes.download.append(item)
                    }
                    if !alreadyTracked {
                        changes.track.append(Pair(ruleKey: ruleKey, itemID: item))
                        remainingTracked[ruleKey, default: []].insert(item)
                    }
                } else if trackedAnywhere.contains(item), !alreadyTracked {
                    // Downloaded by another rule: share ownership. Manual downloads are never tracked.
                    changes.track.append(Pair(ruleKey: ruleKey, itemID: item))
                    remainingTracked[ruleKey, default: []].insert(item)
                }
            }
            for item in (tracked[ruleKey] ?? []).subtracting(wanted).sorted(by: { $0.description < $1.description }) {
                if locked.contains(item) {
                    continue
                }
                changes.untrack.append(Pair(ruleKey: ruleKey, itemID: item))
                remainingTracked[ruleKey]?.remove(item)
            }
        }

        let stillCovered = Set(remainingTracked.values.flatMap { $0 })
        var removed = Set<ItemIdentifier>()
        for pair in changes.untrack where !stillCovered.contains(pair.itemID) && present.contains(pair.itemID) {
            if finished.contains(pair.itemID) && !removeFinished {
                continue
            }
            if removed.insert(pair.itemID).inserted {
                changes.remove.append(pair.itemID)
            }
        }
        return changes
    }
}
