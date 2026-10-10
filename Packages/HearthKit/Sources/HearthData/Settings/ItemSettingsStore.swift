import Foundation
import HearthModel
import Observation
import os
import SwiftData

/// Per audiobook / series / podcast / collection settings.
///
/// Item settings live in SwiftData (key `<storageKey>|<name>`, JSON values) with an in-memory mirror for
/// synchronous reads. Library display state, tabs and pinned tabs are synced through iCloud KVS (with a local
/// fallback).
@MainActor
@Observable
public final class ItemSettingsStore {
    private var values: [String: Data] = [:]
    /// Bumped when KVS values change (locally or from another device).
    private var syncedRevision = 0

    /// User-built tabs mixing libraries.
    public var pinnedTabs: [PinnedTab] = [] {
        didSet {
            guard oldValue != pinnedTabs else { return }
            environment.keyValueStore.set(JSON.encode(pinnedTabs).flatMap { String(data: $0, encoding: .utf8) }, forKey: SyncedKey.pinnedTabs)
        }
    }

    @ObservationIgnored let environment: DataEnvironment
    @ObservationIgnored weak var hearth: HearthData?
    @ObservationIgnored private var writeChain: Task<Void, Never>?
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    private enum Name {
        static let rate = "rate"
        static let sleepTimer = "sleepTimer"
        static let upNext = "upNext"
        static let suggestions = "suggestions"
        static let episodeList = "episodeList"
    }

    private enum SyncedKey {
        static let pinnedTabs = "pinnedTabs"
        static func display(_ key: String) -> String { "display.\(key)" }
        static func sort(_ key: String) -> String { "sort.\(key)" }
        static func tabs(_ library: LibraryIdentifier) -> String { "tabs.\(library)" }
    }

    init(environment: DataEnvironment) {
        self.environment = environment
        values = ModelContext(environment.container).allSettings()
        pinnedTabs = Self.decodePinnedTabs(environment.keyValueStore.string(forKey: SyncedKey.pinnedTabs))

        if environment.isLive, let name = environment.keyValueStore.externalChangeNotification {
            observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.externalChange()
                }
            }
            environment.keyValueStore.synchronize()
        }
    }

    private static func decodePinnedTabs(_ string: String?) -> [PinnedTab] {
        JSON.decode([PinnedTab].self, from: string.map { Data($0.utf8) }) ?? []
    }

    private func externalChange() {
        syncedRevision &+= 1
        let tabs = Self.decodePinnedTabs(environment.keyValueStore.string(forKey: SyncedKey.pinnedTabs))
        if tabs != pinnedTabs {
            pinnedTabs = tabs
        }
    }

    // MARK: Storage

    private func key(_ id: ItemIdentifier, _ name: String) -> String {
        "\(id.storageKey)|\(name)"
    }

    private func value<T: Decodable>(_ type: T.Type, _ id: ItemIdentifier, _ name: String) -> T? {
        JSON.decode(type, from: values[key(id, name)])
    }

    private func set<T: Encodable>(_ value: T?, _ id: ItemIdentifier, _ name: String) {
        let key = key(id, name)
        let data = value.flatMap { JSON.encode($0) }
        guard values[key] != data else { return }
        values[key] = data
        let store = environment.store
        let previous = writeChain
        writeChain = Task {
            await previous?.value
            await store.perform { $0.setSetting(data, for: key) }
        }
    }

    /// Waits for pending writes (tests, before termination).
    func flush() async {
        await writeChain?.value
    }

    func reload() {
        values = ModelContext(environment.container).allSettings()
    }

    // MARK: Playback

    public func playbackRate(for id: ItemIdentifier) -> Double? { value(Double.self, id, Name.rate) }
    public func setPlaybackRate(_ rate: Double?, for id: ItemIdentifier) { set(rate, id, Name.rate) }

    public func sleepTimer(for id: ItemIdentifier) -> SleepTimerPreset? { value(SleepTimerPreset.self, id, Name.sleepTimer) }
    public func setSleepTimer(_ preset: SleepTimerPreset?, for id: ItemIdentifier) { set(preset, id, Name.sleepTimer) }

    public func upNextStrategy(for id: ItemIdentifier) -> UpNextStrategy { value(UpNextStrategy.self, id, Name.upNext) ?? .default }
    public func setUpNextStrategy(_ strategy: UpNextStrategy, for id: ItemIdentifier) { set(strategy == .default ? nil : strategy, id, Name.upNext) }

    public func allowsSuggestions(for id: ItemIdentifier) -> Bool { value(Bool.self, id, Name.suggestions) ?? true }
    public func setAllowsSuggestions(_ allowed: Bool, for id: ItemIdentifier) { set(allowed ? nil : false, id, Name.suggestions) }

    // MARK: Episode lists

    /// Saved settings or the defaults (global default order, filter "not finished").
    public func episodeListSettings(for podcast: ItemIdentifier) -> EpisodeListSettings {
        value(EpisodeListSettings.self, podcast, Name.episodeList) ?? defaultEpisodeListSettings(serial: false)
    }

    /// Like `episodeListSettings(for:)` but serial podcasts default to index ascending.
    public func episodeListSettings(for podcast: Podcast) -> EpisodeListSettings {
        value(EpisodeListSettings.self, podcast.id, Name.episodeList) ?? defaultEpisodeListSettings(serial: podcast.publishingType == .serial)
    }

    public func hasCustomEpisodeListSettings(for podcast: ItemIdentifier) -> Bool {
        values[key(podcast, Name.episodeList)] != nil
    }

    public func setEpisodeListSettings(_ settings: EpisodeListSettings, for podcast: ItemIdentifier) {
        set(settings, podcast, Name.episodeList)
    }

    private func defaultEpisodeListSettings(serial: Bool) -> EpisodeListSettings {
        if serial {
            return EpisodeListSettings(sort: .index, direction: .ascending)
        }
        let settings = hearth?.settings
        return EpisodeListSettings(sort: settings?.defaultEpisodeSort ?? .released, direction: settings?.defaultEpisodeSortDirection ?? .descending)
    }

    /// Applies filter & sort to episodes (uses progress + downloads).
    public func apply(_ settings: EpisodeListSettings, to episodes: [Episode]) -> [Episode] {
        EpisodeListing.apply(
            settings,
            to: episodes,
            progress: { [hearth] in hearth?.progress.progress(for: $0) },
            isDownloaded: { [hearth] in hearth?.downloads.status(of: $0) == .completed }
        )
    }

    /// Distinct seasons of the episodes, naturally sorted.
    public func seasons(in episodes: [Episode]) -> [String] {
        EpisodeListing.seasons(in: episodes)
    }

    // MARK: Library display (iCloud KVS)

    /// Library list display state (synced via iCloud KVS).
    public func displayMode(for key: String) -> DisplayMode {
        _ = syncedRevision
        return environment.keyValueStore.string(forKey: SyncedKey.display(key)).flatMap(DisplayMode.init(rawValue:)) ?? .grid
    }

    public func setDisplayMode(_ mode: DisplayMode, for key: String) {
        environment.keyValueStore.set(mode.rawValue, forKey: SyncedKey.display(key))
        syncedRevision &+= 1
    }

    public func librarySort<Sort: RawRepresentable & Sendable>(for key: String, default: Sort, defaultDirection: SortDirection = .ascending) -> (Sort, SortDirection) where Sort.RawValue == String {
        _ = syncedRevision
        guard let stored = environment.keyValueStore.string(forKey: SyncedKey.sort(key)) else {
            return (`default`, defaultDirection)
        }
        let parts = stored.split(separator: "|", maxSplits: 1).map(String.init)
        let sort = parts.first.flatMap(Sort.init(rawValue:)) ?? `default`
        let direction = parts.count > 1 ? (SortDirection(rawValue: parts[1]) ?? defaultDirection) : defaultDirection
        return (sort, direction)
    }

    public func setLibrarySort<Sort: RawRepresentable & Sendable>(_ sort: Sort, direction: SortDirection, for key: String) where Sort.RawValue == String {
        environment.keyValueStore.set("\(sort.rawValue)|\(direction.rawValue)", forKey: SyncedKey.sort(key))
        syncedRevision &+= 1
    }

    // MARK: Tabs

    /// Tabs configured for a library (iPhone tab bar), `nil` when the user never customised them.
    public func tabs(for library: LibraryIdentifier) -> [LibraryTab]? {
        _ = syncedRevision
        guard let string = environment.keyValueStore.string(forKey: SyncedKey.tabs(library)) else { return nil }
        return JSON.decode([LibraryTab].self, from: Data(string.utf8))
    }

    public func setTabs(_ tabs: [LibraryTab], for library: LibraryIdentifier) {
        let string = JSON.encode(tabs).flatMap { String(data: $0, encoding: .utf8) }
        environment.keyValueStore.set(string, forKey: SyncedKey.tabs(library))
        syncedRevision &+= 1
    }

    /// Drops cached values of a removed connection (database rows are deleted separately).
    func forget(connection: ConnectionID) {
        let prefix = "\(connection)::"
        values = values.filter { !$0.key.hasPrefix(prefix) }
        pinnedTabs.removeAll { $0.library.connectionID == connection }
    }
}
