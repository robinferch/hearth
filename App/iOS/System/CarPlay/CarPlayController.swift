import CarPlay
import HearthData
import HearthModel
import HearthPlayback
import HearthUI
import Observation
import OSLog

/// Builds and refreshes the CarPlay template hierarchy:
/// no connection → "Sign in on your iPhone"; otherwise a tab bar with Listen Now, the libraries chosen in
/// settings (`AppSettings.carPlayLibraries`) and "Other Libraries".
@MainActor
final class CarPlayController {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hearth", category: "CarPlay")

    let interface: CPInterfaceController
    let rows = CarPlayRows()
    private lazy var nowPlaying = CarPlayNowPlaying(controller: self)

    private var listenNowTemplate: CPListTemplate?
    private var libraryTemplates: [LibraryIdentifier: CPListTemplate] = [:]
    private var rootSignature: [String] = []
    private var listenNowSignature: [String] = []
    private var refreshTask: Task<Void, Never>?
    private var isConnected = false

    init(interface: CPInterfaceController) {
        self.interface = interface
    }

    // MARK: Lifecycle

    func connect() {
        isConnected = true
        nowPlaying.start()
        rebuildRoot()
        observeData()
        observePlayer()
    }

    func disconnect() {
        isConnected = false
        refreshTask?.cancel()
        nowPlaying.stop()
    }

    // MARK: Root

    private var data: HearthData { .shared }
    private var settings: AppSettings { .shared }

    /// Identifies the root layout; the root is only replaced when it changes.
    private var currentSignature: [String] {
        if data.connections.connections.isEmpty {
            return ["empty"]
        }
        let libraries = data.connections.allLibraries.map(\.id.description)
        return ["listenNow:\(settings.carPlayShowListenNow)", "other:\(settings.carPlayShowOtherLibraries)"]
            + settings.carPlayLibraries.filter(libraries.contains)
            + ["all:" + libraries.joined(separator: ",")]
    }

    private func rebuildRoot() {
        rootSignature = currentSignature
        listenNowTemplate = nil
        libraryTemplates = [:]
        rows.removeAll()

        let root: CPTemplate
        if data.connections.connections.isEmpty {
            let template = CPListTemplate(title: "Hearth", sections: [])
            template.emptyViewTitleVariants = [String(localized: "Sign in on your iPhone", table: "System")]
            template.emptyViewSubtitleVariants = [String(localized: "Add your audiobookshelf server in the Hearth app to listen in the car.", table: "System")]
            root = template
        } else {
            root = CPTabBarTemplate(templates: makeTabs())
        }
        interface.setRootTemplate(root, animated: false) { _, error in
            if let error {
                Self.logger.error("Setting the root template failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func makeTabs() -> [CPTemplate] {
        let maximum = CPTabBarTemplate.maximumTabCount
        let allLibraries = data.connections.allLibraries
        let chosen = settings.carPlayLibraries.compactMap { key in allLibraries.first { $0.id.description == key } }
        let others = allLibraries.filter { library in !chosen.contains { $0.id == library.id } }
        let showOthers = settings.carPlayShowOtherLibraries && !others.isEmpty

        var tabs = [CPTemplate]()
        if settings.carPlayShowListenNow || (chosen.isEmpty && !showOthers) {
            let template = CPListTemplate(title: String(localized: "Listen Now", table: "System"), sections: [])
            template.tabImage = UIImage(systemName: "headphones")
            template.showsSpinnerWhileEmpty = true
            template.emptyViewTitleVariants = [String(localized: "Nothing to listen to", table: "System")]
            listenNowTemplate = template
            tabs.append(template)
            refreshListenNow()
        }
        let libraryCapacity = maximum - tabs.count - (showOthers ? 1 : 0)
        for library in chosen.prefix(max(0, libraryCapacity)) {
            tabs.append(libraryTemplate(library))
        }
        if showOthers {
            let template = CPListTemplate(title: String(localized: "Other Libraries", table: "System"), sections: [
                CPListSection(items: others.map { library in
                    let item = CPListItem(text: library.name, detailText: data.connections.connection(library.connectionID)?.displayName, image: UIImage(systemName: library.systemImage), accessoryImage: nil, accessoryType: .disclosureIndicator)
                    item.handler = { [weak self] _, completion in
                        guard let self else { return completion() }
                        let template = self.libraryTemplate(library)
                        self.push(template)
                        completion()
                    }
                    return item
                }),
            ])
            template.tabTitle = String(localized: "Libraries", table: "System")
            template.tabImage = UIImage(systemName: "books.vertical")
            tabs.append(template)
        }
        return tabs
    }

    // MARK: Listen Now

    /// Identifies the Listen Now tab's rows (membership and order, not progress).
    private var currentListenNowSignature: [String] {
        let downloads = data.downloads
        return ["offline:\(data.connections.isOffline)"]
            + data.progress.inProgress().map(\.itemID.description)
            + ["downloads"] + downloads.downloadedAudiobooks().map(\.id.description)
            + ["episodes"] + downloads.downloadedEpisodes().map(\.id.description)
    }

    func refreshListenNow() {
        guard let template = listenNowTemplate else { return }
        listenNowSignature = currentListenNowSignature
        Task {
            let downloads = data.downloads
            var sections = [CPListSection]()
            let listenNow = await data.items.listenNow()
            if !listenNow.isEmpty {
                sections.append(CPListSection(items: listenNow.map { rows.row(for: $0, controller: self, origin: .listenNow) }, header: String(localized: "Listen Now", table: "System"), sectionIndexTitle: nil))
            }
            let audiobooks = downloads.downloadedAudiobooks().sorted { $0.sortName < $1.sortName }
            if !audiobooks.isEmpty {
                sections.append(CPListSection(items: audiobooks.map { rows.row(for: .audiobook($0), controller: self, origin: .carPlay) }, header: String(localized: "Downloaded Audiobooks", table: "System"), sectionIndexTitle: nil))
            }
            for podcast in downloads.downloadedPodcasts().sorted(by: { $0.sortName < $1.sortName }) {
                let episodes = downloads.downloadedEpisodes(podcast: podcast.id).sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
                guard !episodes.isEmpty else { continue }
                sections.append(CPListSection(items: episodes.map { rows.row(for: .episode($0), controller: self, origin: .podcast(podcast.id)) }, header: podcast.name, sectionIndexTitle: nil))
            }
            template.updateSections(Self.limited(sections))
        }
    }

    // MARK: Libraries

    func libraryTemplate(_ library: Library) -> CPListTemplate {
        if let template = libraryTemplates[library.id] {
            return template
        }
        let template = CPListTemplate(title: library.name, sections: [])
        template.tabImage = UIImage(systemName: library.systemImage)
        template.showsSpinnerWhileEmpty = true
        template.emptyViewTitleVariants = [String(localized: "Nothing here yet", table: "System")]
        libraryTemplates[library.id] = template
        Task { await self.load(library, into: template) }
        return template
    }

    private func load(_ library: Library, into template: CPListTemplate) async {
        switch library.mediaType {
        case .audiobooks:
            template.updateSections(Self.limited(await homeSections(library)))
        case .podcasts:
            template.updateSections(Self.limited(await podcastSections(library)))
        }
    }

    /// Home shelves of an audiobook library; falls back to its downloaded books when offline.
    private func homeSections(_ library: Library) async -> [CPListSection] {
        if isReachable(library.connectionID), let client = try? data.connections.client(for: library.connectionID), let shelves = try? await client.home(library: library) {
            var sections = [CPListSection]()
            for shelf in shelves {
                data.items.remember(shelf.items)
                let items: [CPListItem] = shelf.items.compactMap { item in
                    switch item {
                    case .audiobook(let audiobook): rows.row(for: .audiobook(audiobook), controller: self, origin: .carPlay)
                    case .episode(let episode): rows.row(for: .episode(episode), controller: self, origin: .carPlay)
                    case .series(let series): groupingRow(series.id, title: series.name, detail: HearthFormat.bookCount(series.bookCount))
                    case .podcast(let podcast): groupingRow(podcast.id, title: podcast.name, detail: podcast.authorLine)
                    case .collection(let collection): groupingRow(collection.id, title: collection.name, detail: nil)
                    case .person: nil
                    }
                }
                if !items.isEmpty {
                    sections.append(CPListSection(items: items, header: shelf.label, sectionIndexTitle: nil))
                }
            }
            if !sections.isEmpty {
                return sections
            }
        }
        let downloaded = data.downloads.downloadedAudiobooks(in: library.id)
        guard !downloaded.isEmpty else { return [] }
        return [CPListSection(items: downloaded.map { rows.row(for: .audiobook($0), controller: self, origin: .carPlay) }, header: String(localized: "Downloaded", table: "System"), sectionIndexTitle: nil)]
    }

    /// Podcasts of a library (alphabetical); each opens its episodes.
    private func podcastSections(_ library: Library) async -> [CPListSection] {
        var podcasts = [Podcast]()
        if isReachable(library.connectionID), let client = try? data.connections.client(for: library.connectionID) {
            podcasts = (try? await client.podcasts(library: library.id, sort: .title, direction: .ascending, page: 0, limit: 200).items) ?? []
            data.items.remember(podcasts.map(AnyItem.podcast))
        }
        if podcasts.isEmpty {
            podcasts = data.downloads.downloadedPodcasts(in: library.id)
        }
        guard !podcasts.isEmpty else { return [] }
        return [CPListSection(items: podcasts.map { podcast in
            let detail = podcast.incompleteEpisodeCount.map { HearthFormat.unplayedCount($0) } ?? podcast.authorLine
            return groupingRow(podcast.id, title: podcast.name, detail: detail)
        })]
    }

    /// A row that opens a grouping (podcast, series, collection) in a pushed list.
    private func groupingRow(_ id: ItemIdentifier, title: String, detail: String?) -> CPListItem {
        let item = CPListItem(text: title, detailText: detail, image: CarPlayRows.placeholder(for: id.kind), accessoryImage: nil, accessoryType: .disclosureIndicator)
        rows.loadImage(for: id, into: item)
        item.handler = { [weak self] _, completion in
            guard let self else { return completion() }
            self.push(self.groupingTemplate(id, title: title))
            completion()
        }
        return item
    }

    /// Episodes of a podcast (saved episode order/filter), books of a series or items of a collection.
    func groupingTemplate(_ id: ItemIdentifier, title: String) -> CPListTemplate {
        let template = CPListTemplate(title: title, sections: [])
        template.showsSpinnerWhileEmpty = true
        template.emptyViewTitleVariants = [String(localized: "Nothing here yet", table: "System")]
        Task {
            var items = [AnyPlayableItem]()
            let origin: PlaybackOrigin
            switch id.kind {
            case .podcast:
                origin = .podcast(id)
                if let result = try? await data.items.podcast(id) {
                    let settings = data.itemSettings.episodeListSettings(for: result.podcast)
                    var listing = settings
                    listing.filter = .all
                    items = data.itemSettings.apply(listing, to: result.episodes).map(AnyPlayableItem.episode)
                }
            case .series:
                origin = .series(id)
                if case .series(let series)? = try? await data.items.item(id) {
                    items = series.audiobooks.map(AnyPlayableItem.audiobook)
                }
            default:
                origin = .collection(id)
                if case .collection(let collection)? = try? await data.items.item(id) {
                    items = collection.items
                }
            }
            template.emptyViewTitleVariants = [String(localized: "Nothing here yet", table: "System")]
            template.showsSpinnerWhileEmpty = false
            template.updateSections(Self.limited([CPListSection(items: items.map { rows.row(for: $0, controller: self, origin: origin) })]))
        }
        return template
    }

    /// Mirrors `ConnectionStore.isAvailable` (internal to HearthData).
    private func isReachable(_ id: ConnectionID) -> Bool {
        let connections = data.connections
        let status = connections.status[id]
        return !connections.isOffline && connections.connection(id) != nil && status != .offline && status != .unauthorized
    }

    // MARK: Navigation & playback

    func push(_ template: CPTemplate) {
        interface.pushTemplate(template, animated: true) { _, error in
            if let error {
                Self.logger.error("Pushing a template failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func showNowPlaying() {
        let template = CPNowPlayingTemplate.shared
        guard interface.topTemplate !== template else { return }
        // Already on the stack (e.g. a row in Up Next or the chapter list was tapped): go back to it. Pushing a
        // template twice fails.
        if interface.templates.contains(where: { $0 === template }) {
            interface.pop(to: template, animated: true) { _, error in
                if let error {
                    Self.logger.error("Popping to Now Playing failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        } else {
            push(template)
        }
    }

    /// Tap on an item row: toggles the current item, otherwise starts it and shows Now Playing.
    func play(_ id: ItemIdentifier, origin: PlaybackOrigin) async {
        let player = AudioPlayer.shared
        if player.isCurrent(id) {
            player.togglePlayPause()
            showNowPlaying()
            return
        }
        do {
            try await player.play(id, origin: origin)
            showNowPlaying()
        } catch {
            showError(error)
        }
    }

    func showError(_ error: any Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let alert = CPAlertTemplate(titleVariants: [message], actions: [
            CPAlertAction(title: String(localized: "OK", table: "System"), style: .cancel) { [weak self] _ in
                self?.interface.dismissTemplate(animated: true, completion: nil)
            },
        ])
        interface.presentTemplate(alert, animated: true, completion: nil)
    }

    // MARK: Refreshing

    /// Rebuilds Listen Now when its items, downloads, connections or CarPlay settings change. Progress alone
    /// (reported every 30 s while playing) only updates the visible rows.
    private func observeData() {
        guard isConnected else { return }
        withObservationTracking {
            _ = currentListenNowSignature
            _ = data.connections.connections
            _ = data.connections.libraries
            _ = data.connections.isOffline
            _ = settings.carPlayLibraries
            _ = settings.carPlayShowListenNow
            _ = settings.carPlayShowOtherLibraries
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.scheduleRefresh()
                self?.observeData()
            }
        }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, isConnected else { return }
            if currentSignature != rootSignature {
                rebuildRoot()
            } else if currentListenNowSignature != listenNowSignature {
                refreshListenNow()
            } else {
                rows.updatePlaybackState()
            }
        }
    }

    /// Updates now-playing indicators and progress of visible rows.
    private func observePlayer() {
        guard isConnected else { return }
        let player = AudioPlayer.shared
        withObservationTracking {
            _ = player.currentItem?.id
            _ = player.isPlaying
            _ = player.queue.count
            _ = player.upNext.count
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.rows.updatePlaybackState()
                self?.nowPlaying.update()
                self?.observePlayer()
            }
        }
    }

    /// Keeps the total item/section count within the head unit's limits.
    static func limited(_ sections: [CPListSection]) -> [CPListSection] {
        let maximumItems = Int(CPListTemplate.maximumItemCount)
        let maximumSections = Int(CPListTemplate.maximumSectionCount)
        var remaining = maximumItems
        var result = [CPListSection]()
        for section in sections.prefix(maximumSections) where remaining > 0 {
            let items = Array(section.items.prefix(remaining))
            remaining -= items.count
            result.append(CPListSection(items: items, header: section.header, sectionIndexTitle: section.sectionIndexTitle))
        }
        return result
    }
}
