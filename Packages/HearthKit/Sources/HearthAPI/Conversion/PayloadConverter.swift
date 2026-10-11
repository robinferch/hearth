import Foundation
import HearthModel
import os

/// Converts server payloads into HearthModel values for one connection.
///
/// Every converted library item is registered in the `LibraryItemDirectory` so that later payloads that only
/// carry a `libraryItemId` (progress, bookmarks) can be mapped to complete `ItemIdentifier`s.
struct PayloadConverter: Sendable {
    let connectionID: ConnectionID
    let host: URL
    let directory: LibraryItemDirectory

    private static let logger = Logger.api(PayloadConverter.self)

    init(connectionID: ConnectionID, host: URL, directory: LibraryItemDirectory = LibraryItemDirectory()) {
        self.connectionID = connectionID
        self.host = host
        self.directory = directory
    }

    // MARK: Identifiers

    func identifier(_ kind: ItemIdentifier.Kind, library: String, primary: String, grouping: String? = nil) -> ItemIdentifier {
        ItemIdentifier(kind: kind, connectionID: connectionID, libraryID: library, primaryID: primary, groupingID: grouping)
    }

    func libraryIdentifier(_ libraryID: String) -> LibraryIdentifier {
        LibraryIdentifier(connectionID: connectionID, libraryID: libraryID)
    }

    /// Narrators have no server id; their identity is the base64 encoded name.
    static func narratorPrimaryID(name: String) -> String {
        Data(name.utf8).base64EncodedString()
    }

    static func narratorName(primaryID: String) -> String {
        let candidate = primaryID.removingPercentEncoding ?? primaryID
        if let data = Data(base64Encoded: candidate), let name = String(data: data, encoding: .utf8), !name.isEmpty {
            return name
        }
        return primaryID
    }

    /// The library id of an item, registering the item for later lookups.
    private func resolveLibrary(of item: LibraryItemPayload, fallback: String?) -> String {
        let libraryID = item.libraryID ?? fallback ?? directory.entry(for: item.id)?.libraryID ?? ""
        if libraryID.isEmpty {
            Self.logger.warning("Library item \(item.id, privacy: .public) without library id")
        }
        directory.register(itemID: item.id, libraryID: libraryID, isPodcast: item.isPodcast)
        return libraryID
    }

    /// Records the library of `item` for later progress/bookmark lookups.
    func register(_ item: LibraryItemPayload, library fallback: String?) {
        _ = resolveLibrary(of: item, fallback: fallback)
    }

    // MARK: Libraries

    func library(_ payload: LibraryPayload) -> Library? {
        let mediaType: Library.MediaType
        switch payload.mediaType {
        case "book": mediaType = .audiobooks
        case "podcast": mediaType = .podcasts
        default: return nil
        }
        return Library(id: libraryIdentifier(payload.id), name: payload.name, mediaType: mediaType, displayOrder: payload.displayOrder, icon: payload.icon)
    }

    func filterData(_ payload: FilterDataPayload?) -> LibraryFilterData {
        LibraryFilterData(genres: payload?.genres ?? [], tags: payload?.tags ?? [], languages: payload?.languages ?? [])
    }

    // MARK: Books

    func audiobook(_ item: LibraryItemPayload, library fallback: String? = nil) -> Audiobook? {
        guard item.isBook, let media = item.media else { return nil }
        let libraryID = resolveLibrary(of: item, fallback: fallback)
        let metadata = media.metadata

        let authors = metadata.map { metadata in
            metadata.authors.isEmpty ? Self.splitNames(metadata.authorName) : metadata.authors.map(\.name)
        } ?? []
        let narrators = metadata.map { metadata in
            metadata.narrators.isEmpty ? Self.splitNames(metadata.narratorName) : metadata.narrators
        } ?? []
        let series = metadata.map { metadata in
            metadata.series.isEmpty
                ? Self.parseSeriesName(metadata.seriesName)
                : metadata.series.map { SeriesFragment(id: $0.id, name: $0.name, sequence: $0.sequence) }
        } ?? []

        return Audiobook(
            id: identifier(.audiobook, library: libraryID, primary: item.id),
            name: metadata?.title ?? "",
            subtitle: metadata?.subtitle,
            authors: authors,
            narrators: narrators,
            series: series,
            descriptionHTML: metadata?.description,
            genres: metadata?.genres ?? [],
            tags: media.tags,
            addedAt: item.addedAt,
            released: metadata?.publishedYear ?? metadata?.publishedDate,
            publisher: metadata?.publisher,
            language: metadata?.language,
            isbn: metadata?.isbn,
            asin: metadata?.asin,
            explicit: metadata?.explicit ?? false,
            abridged: metadata?.abridged ?? false,
            duration: media.duration ?? 0,
            size: item.size ?? media.size,
            pdfs: pdfs(of: item),
            hasAudio: media.hasAudio
        )
    }

    func pdfs(of item: LibraryItemPayload) -> [PDFFile] {
        item.libraryFiles.filter(\.isPDF).map { file in
            let filename = file.metadata?.filename ?? file.ino
            let name = (filename as NSString).deletingPathExtension
            return PDFFile(ino: file.ino, name: name.isEmpty ? filename : name)
        }
    }

    /// Splits `"A, B"` into names.
    static func splitNames(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Parses `"Name #1, Other #2.5"` into series fragments.
    static func parseSeriesName(_ value: String?) -> [SeriesFragment] {
        splitNames(value).map { entry in
            if let range = entry.range(of: " #", options: .backwards) {
                let name = entry[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let sequence = entry[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    return SeriesFragment(id: nil, name: name, sequence: sequence.isEmpty ? nil : sequence)
                }
            }
            return SeriesFragment(id: nil, name: entry, sequence: nil)
        }
    }

    func libraryEntry(_ item: LibraryItemPayload, library: String?) -> LibraryEntry? {
        guard let audiobook = audiobook(item, library: library) else { return nil }
        guard let collapsed = item.collapsedSeries else {
            return .audiobook(audiobook)
        }
        let series = Series(
            id: identifier(.series, library: audiobook.id.libraryID, primary: collapsed.id),
            name: collapsed.name,
            audiobooks: [audiobook],
            bookCount: collapsed.numBooks ?? max(collapsed.libraryItemIDs.count, 1)
        )
        return .collapsedSeries(series)
    }

    // MARK: Podcasts

    func podcast(_ item: LibraryItemPayload, library fallback: String? = nil) -> Podcast? {
        guard item.isPodcast, let media = item.media else { return nil }
        let libraryID = resolveLibrary(of: item, fallback: fallback)
        let metadata = media.metadata

        return Podcast(
            id: identifier(.podcast, library: libraryID, primary: item.id),
            name: metadata?.title ?? "",
            authors: metadata?.author.map { [$0] } ?? [],
            descriptionHTML: metadata?.description,
            genres: metadata?.genres ?? [],
            addedAt: item.addedAt,
            released: metadata?.releaseDate,
            explicit: metadata?.explicit ?? false,
            publishingType: metadata?.type?.lowercased() == "serial" ? .serial : .episodic,
            episodeCount: media.numEpisodes ?? media.episodes.count,
            incompleteEpisodeCount: item.numEpisodesIncomplete,
            feedURL: metadata?.feedURL.flatMap(URL.init(string:)),
            language: metadata?.language
        )
    }

    /// Converts an episode. `podcastItem` supplies the podcast name/author and library when the episode lacks them.
    func episode(_ payload: EpisodePayload, podcastItem: LibraryItemPayload? = nil, library fallback: String? = nil) -> Episode? {
        guard let podcastID = payload.libraryItemID ?? podcastItem?.id else {
            Self.logger.warning("Episode \(payload.id, privacy: .public) without podcast id")
            return nil
        }

        let libraryID: String
        if let podcastItem {
            libraryID = resolveLibrary(of: podcastItem, fallback: payload.libraryID ?? fallback)
        } else {
            libraryID = payload.libraryID ?? fallback ?? directory.entry(for: podcastID)?.libraryID ?? ""
            directory.register(itemID: podcastID, libraryID: libraryID, isPodcast: true)
        }

        let podcastMetadata = podcastItem?.media?.metadata ?? payload.podcast?.metadata
        return Episode(
            id: identifier(.episode, library: libraryID, primary: payload.id, grouping: podcastID),
            name: payload.title ?? "",
            podcastName: podcastMetadata?.title ?? "",
            authors: podcastMetadata?.author.map { [$0] } ?? [],
            descriptionHTML: payload.description ?? payload.subtitle,
            addedAt: payload.addedAt,
            publishedAt: payload.publishedAt,
            season: payload.season,
            episode: payload.episode,
            type: payload.episodeType.flatMap { Episode.EpisodeType(rawValue: $0.lowercased()) } ?? .full,
            duration: payload.resolvedDuration,
            size: payload.resolvedSize
        )
    }

    func episodes(of item: LibraryItemPayload, library: String? = nil) -> [Episode] {
        (item.media?.episodes ?? []).compactMap { episode($0, podcastItem: item, library: library) }
    }

    /// Chapters of an episode: server chapters, or timestamps parsed from the show notes.
    func chapters(of episode: EpisodePayload) -> [Chapter] {
        let server = chapters(episode.chapters)
        if !server.isEmpty {
            return server
        }
        guard let description = episode.description else { return [] }
        return ChapterParser.parse(description: description, duration: episode.resolvedDuration)
    }

    // MARK: People & groupings

    func author(_ payload: AuthorPayload, library fallback: String? = nil) -> Person {
        Person(
            id: identifier(.author, library: payload.libraryID ?? fallback ?? "", primary: payload.id),
            name: payload.name,
            descriptionHTML: payload.description,
            addedAt: payload.addedAt,
            bookCount: payload.numBooks ?? payload.libraryItems.count,
            hasImage: payload.imagePath != nil
        )
    }

    func narrator(_ payload: NarratorPayload, library: String) -> Person {
        narrator(name: payload.name, bookCount: payload.numBooks ?? 0, library: library)
    }

    func narrator(name: String, bookCount: Int, library: String) -> Person {
        Person(id: identifier(.narrator, library: library, primary: Self.narratorPrimaryID(name: name)), name: name, bookCount: bookCount)
    }

    func series(_ payload: SeriesPayload, library fallback: String? = nil) -> Series {
        let libraryID = payload.libraryID ?? fallback ?? payload.books.first?.libraryID ?? ""
        let audiobooks = payload.books.compactMap { audiobook($0, library: libraryID) }
        return Series(
            id: identifier(.series, library: libraryID, primary: payload.id),
            name: payload.name,
            descriptionHTML: payload.description,
            addedAt: payload.addedAt,
            audiobooks: audiobooks,
            bookCount: payload.hasBooks ? payload.books.count : nil,
            totalDuration: payload.totalDuration
        )
    }

    func collection(_ payload: CollectionPayload, library fallback: String? = nil, isPlaylist: Bool) -> ItemCollection {
        let libraryID = payload.libraryID ?? fallback ?? ""
        let items: [AnyPlayableItem]
        if isPlaylist {
            items = payload.items.compactMap { entry -> AnyPlayableItem? in
                if let episodePayload = entry.episode {
                    var episodePayload = episodePayload
                    if episodePayload.libraryItemID == nil {
                        episodePayload.libraryItemID = entry.libraryItemID
                    }
                    return episode(episodePayload, podcastItem: entry.libraryItem, library: libraryID).map(AnyPlayableItem.episode)
                }
                return entry.libraryItem.flatMap { audiobook($0, library: libraryID) }.map(AnyPlayableItem.audiobook)
            }
        } else {
            items = payload.books.compactMap { audiobook($0, library: libraryID) }.map(AnyPlayableItem.audiobook)
        }

        return ItemCollection(
            id: identifier(isPlaylist ? .playlist : .collection, library: libraryID, primary: payload.id),
            name: payload.name,
            descriptionHTML: payload.description,
            addedAt: payload.createdAt,
            items: items
        )
    }

    // MARK: Home & search

    func homeRows(_ shelves: [ShelfPayload], library: String) -> [HomeRow] {
        shelves.compactMap { shelf -> HomeRow? in
            let items: [AnyItem]
            switch (shelf.type, shelf.entities) {
            case ("book", .libraryItems(let entities)):
                items = entities.compactMap { audiobook($0, library: library) }.map(AnyItem.audiobook)
            case ("podcast", .libraryItems(let entities)):
                items = entities.compactMap { podcast($0, library: library) }.map(AnyItem.podcast)
            case ("episode", .libraryItems(let entities)):
                items = entities.compactMap { item in
                    item.recentEpisode.flatMap { episode($0, podcastItem: item, library: library) }
                }.map(AnyItem.episode)
            case ("series", .series(let entities)):
                items = entities.map { series($0, library: library) }.map(AnyItem.series)
            case ("authors", .authors(let entities)):
                items = entities.map { author($0, library: library) }.map(AnyItem.person)
            default:
                return nil
            }
            guard !items.isEmpty else { return nil }
            return HomeRow(id: shelf.id, label: shelf.label, items: items)
        }
    }

    func searchResults(_ payload: SearchResponsePayload, library: String) -> SearchResults {
        SearchResults(
            audiobooks: payload.books.compactMap { audiobook($0, library: library) },
            podcasts: payload.podcasts.compactMap { podcast($0, library: library) },
            episodes: payload.episodes.compactMap { item in
                item.recentEpisode.flatMap { episode($0, podcastItem: item, library: library) }
            },
            authors: payload.authors.map { author($0, library: library) },
            narrators: payload.narrators.map { narrator($0, library: library) },
            series: payload.series.map { result in
                var series = series(result.series, library: library)
                if series.audiobooks.isEmpty {
                    series.audiobooks = result.books.compactMap { audiobook($0, library: library) }
                    series.bookCount = series.audiobooks.count
                }
                return series
            }
        )
    }

    // MARK: Playback details

    func chapters(_ payloads: [ChapterPayload]) -> [Chapter] {
        payloads
            .sorted { $0.start < $1.start }
            .enumerated()
            .map { index, chapter in
                Chapter(id: chapter.id ?? index, start: chapter.start, end: max(chapter.end, chapter.start), title: chapter.title)
            }
    }

    static func fileExtension(_ ext: String?, filename: String?) -> String {
        let raw = ext ?? filename.map { ($0 as NSString).pathExtension } ?? ""
        return raw.hasPrefix(".") ? String(raw.dropFirst()) : raw
    }

    func audioFile(_ track: AudioTrackPayload) -> AudioFile? {
        guard let ino = track.resolvedIno else { return nil }
        return AudioFile(
            ino: ino,
            fileExtension: Self.fileExtension(track.metadata?.ext, filename: track.metadata?.filename),
            offset: track.startOffset,
            duration: track.duration,
            mimeType: track.mimeType
        )
    }

    /// Audio files of a book in playback order with cumulative offsets.
    func audioFiles(of media: MediaPayload) -> [AudioFile] {
        if !media.tracks.isEmpty {
            return media.tracks.compactMap(audioFile)
        }
        var offset: TimeInterval = 0
        return media.includedAudioFiles.map { file in
            defer { offset += file.duration }
            return AudioFile(
                ino: file.ino,
                fileExtension: Self.fileExtension(file.metadata?.ext, filename: file.metadata?.filename),
                offset: offset,
                duration: file.duration,
                mimeType: file.mimeType
            )
        }
    }

    /// Converts an expanded item into playback details. `episodeID` selects an episode of a podcast.
    func playableDetails(_ item: LibraryItemPayload, episodeID: String?, library: String?) -> PlayableItemDetails? {
        guard let media = item.media else { return nil }

        if let episodeID {
            guard let payload = media.episodes.first(where: { $0.id == episodeID }),
                  let episode = episode(payload, podcastItem: item, library: library) else {
                return nil
            }
            var files: [AudioFile] = []
            if let track = payload.audioTrack, let file = audioFile(track) {
                files = [file]
            } else if let file = payload.audioFile {
                files = [AudioFile(
                    ino: file.ino,
                    fileExtension: Self.fileExtension(file.metadata?.ext, filename: file.metadata?.filename),
                    offset: 0,
                    duration: file.duration,
                    mimeType: file.mimeType
                )]
            }
            let progress = item.userMediaProgress.flatMap { $0.episodeID == nil || $0.episodeID == episodeID ? $0 : nil }
            return PlayableItemDetails(
                item: .episode(episode),
                audioFiles: files,
                chapters: chapters(of: payload),
                pdfs: [],
                progress: progress.map { self.progress($0, itemID: episode.id) }
            )
        }

        guard let audiobook = audiobook(item, library: library) else { return nil }
        return PlayableItemDetails(
            item: .audiobook(audiobook),
            audioFiles: audioFiles(of: media),
            chapters: chapters(media.chapters),
            pdfs: audiobook.pdfs,
            progress: item.userMediaProgress.map { progress($0, itemID: audiobook.id) }
        )
    }

    // MARK: Progress & bookmarks

    /// Identifier for a progress/bookmark entry using the directory. `nil` if the library is unknown.
    func playableIdentifier(libraryItemID: String, episodeID: String?) -> ItemIdentifier? {
        guard let entry = directory.entry(for: libraryItemID) else { return nil }
        if let episodeID {
            return identifier(.episode, library: entry.libraryID, primary: episodeID, grouping: libraryItemID)
        }
        return identifier(.audiobook, library: entry.libraryID, primary: libraryItemID)
    }

    func progress(_ payload: MediaProgressPayload) -> ProgressEntity? {
        playableIdentifier(libraryItemID: payload.libraryItemID, episodeID: payload.episodeID).map { progress(payload, itemID: $0) }
    }

    func progress(_ payload: MediaProgressPayload, itemID: ItemIdentifier) -> ProgressEntity {
        // `isFinished` is authoritative: the server may mark items finished slightly before the end.
        let value = payload.isFinished ? 1 : min(max(payload.progress, 0), (1.0).nextDown)
        return ProgressEntity(
            id: payload.id,
            itemID: itemID,
            progress: value,
            duration: payload.duration.flatMap { $0 > 0 ? $0 : nil },
            currentTime: payload.currentTime,
            startedAt: payload.startedAt,
            lastUpdate: payload.lastUpdate ?? payload.startedAt ?? .distantPast,
            finishedAt: payload.finishedAt,
            hideFromContinueListening: payload.hideFromContinueListening
        )
    }

    func bookmark(_ payload: BookmarkPayload) -> Bookmark? {
        guard let itemID = playableIdentifier(libraryItemID: payload.libraryItemID, episodeID: nil) else { return nil }
        return bookmark(payload, itemID: itemID)
    }

    func bookmark(_ payload: BookmarkPayload, itemID: ItemIdentifier) -> Bookmark {
        Bookmark(itemID: itemID, time: BookmarkTimeDirectory.second(of: payload.time), note: payload.title, created: payload.createdAt ?? .now)
    }

    // MARK: Sessions

    func playbackSession(_ payload: PlaybackSessionPayload) -> PlaybackSessionInfo {
        let tracks = payload.audioTracks.enumerated().compactMap { index, track -> AudioTrack? in
            guard let contentURL = track.contentURL, let url = URLBuilder.resolve(serverPath: contentURL, host: host) else {
                return nil
            }
            return AudioTrack(index: track.index ?? index, offset: track.startOffset, duration: track.duration, url: url, mimeType: track.mimeType)
        }

        var chapters = chapters(payload.chapters)
        if chapters.isEmpty, let episodeID = payload.episodeID,
           let episode = payload.libraryItem?.media?.episodes.first(where: { $0.id == episodeID }) {
            chapters = self.chapters(of: episode)
        }

        let duration = payload.duration > 0 ? payload.duration : tracks.reduce(0) { $0 + $1.duration }
        return PlaybackSessionInfo(
            id: payload.id,
            startTime: payload.currentTime ?? payload.startTime ?? 0,
            duration: duration,
            tracks: tracks,
            chapters: chapters
        )
    }

    func listeningSession(_ payload: PlaybackSessionPayload) -> ListeningSession {
        var itemID: ItemIdentifier?
        if let libraryItemID = payload.libraryItemID {
            let libraryID = payload.libraryID ?? directory.entry(for: libraryItemID)?.libraryID
            if let libraryID {
                if let episodeID = payload.episodeID {
                    itemID = identifier(.episode, library: libraryID, primary: episodeID, grouping: libraryItemID)
                } else {
                    itemID = identifier(.audiobook, library: libraryID, primary: libraryItemID)
                }
                directory.register(itemID: libraryItemID, libraryID: libraryID, isPodcast: payload.episodeID != nil || payload.mediaType == "podcast")
            }
        }

        let startedAt = payload.startedAt ?? payload.updatedAt ?? .distantPast
        return ListeningSession(
            id: payload.id,
            itemID: itemID,
            displayTitle: payload.displayTitle ?? payload.mediaMetadataTitle,
            timeListening: payload.timeListening,
            startTime: payload.startTime ?? 0,
            currentTime: payload.currentTime ?? 0,
            startedAt: startedAt,
            updatedAt: payload.updatedAt ?? startedAt,
            deviceName: payload.deviceInfo?.displayName
        )
    }

    func listeningStats(_ payload: ListeningStatsPayload) -> ListeningStats {
        let topItems = payload.items.values
            .filter { $0.timeListening > 0 }
            .sorted { $0.timeListening > $1.timeListening }
            .map { ListeningStats.TopItem(id: $0.id, title: $0.title ?? "", timeListening: $0.timeListening) }
        return ListeningStats(days: payload.days, totalTime: payload.totalTime, today: payload.today, topItems: topItems)
    }
}
