import Foundation
import HearthModel

// MARK: Libraries & lists

extension APIClient {
    func libraries() async throws -> [Library] {
        let payload = try await fetch(LibrariesResponsePayload.self, APIRequest.get("api", "libraries").cached())
        return payload.libraries
            .compactMap(converter.library)
            .sorted { ($0.displayOrder, $0.name) < ($1.displayOrder, $1.name) }
    }

    func filterData(library: LibraryIdentifier) async throws -> LibraryFilterData {
        let request = APIRequest.get("api", "libraries", library.libraryID, query: [URLQueryItem(name: "include", value: "filterdata")]).cached()
        let payload = try await fetch(LibraryWithFilterDataPayload.self, request)
        return converter.filterData(payload.filterdata)
    }

    func home(library: Library) async throws -> [HomeRow] {
        let libraryID = library.id.libraryID
        let shelves = try await fetch([Failable<ShelfPayload>].self, APIRequest.get("api", "libraries", libraryID, "personalized").cached())
        return converter.homeRows(shelves.compactMap(\.value), library: libraryID)
    }

    func recentEpisodes(library: LibraryIdentifier, limit: Int) async throws -> [Episode] {
        let request = APIRequest.get("api", "libraries", library.libraryID, "recent-episodes", query: Self.pageQuery(page: 0, limit: limit)).cached()
        let payload = try await fetch(RecentEpisodesPayload.self, request)
        return payload.episodes.compactMap { converter.episode($0, library: library.libraryID) }
    }

    func audiobooks(library: LibraryIdentifier, sort: AudiobookSortOrder?, direction: SortDirection, filter: LibraryItemFilter?, collapseSeries: Bool, page: Int, limit: Int) async throws -> Page<LibraryEntry> {
        let request = Self.itemsRequest(library: library.libraryID, sort: sort?.rawValue, direction: direction, filter: filter, collapseSeries: collapseSeries, page: page, limit: limit)
        let payload = try await fetch(PagedPayload<LibraryItemPayload>.self, request)
        let entries = payload.results.compactMap { converter.libraryEntry($0, library: library.libraryID) }
        return Page(items: entries, total: payload.total ?? entries.count, page: page)
    }

    /// `GET api/libraries/{id}/items` with the audiobook list parameters.
    static func itemsRequest(library: String, sort: String?, direction: SortDirection, filter: LibraryItemFilter?, collapseSeries: Bool, page: Int, limit: Int) -> APIRequest {
        var query = pageQuery(page: page, limit: limit)
        if let sort {
            query.append(URLQueryItem(name: "sort", value: sort))
        }
        query.append(flag("desc", direction.isDescending))
        query.append(flag("collapseseries", collapseSeries))
        if let filter = filter?.queryValue {
            query.append(URLQueryItem(name: "filter", value: filter))
        }
        return APIRequest.get("api", "libraries", library, "items", query: query).cached()
    }

    func podcasts(library: LibraryIdentifier, sort: PodcastSortOrder, direction: SortDirection, page: Int, limit: Int) async throws -> Page<Podcast> {
        let query = Self.pageQuery(page: page, limit: limit) + [
            URLQueryItem(name: "sort", value: sort.rawValue),
            Self.flag("desc", direction.isDescending),
            URLQueryItem(name: "include", value: "numEpisodesIncomplete"),
        ]
        let payload = try await fetch(PagedPayload<LibraryItemPayload>.self, APIRequest.get("api", "libraries", library.libraryID, "items", query: query).cached())
        let podcasts = payload.results.compactMap { converter.podcast($0, library: library.libraryID) }
        return Page(items: podcasts, total: payload.total ?? podcasts.count, page: page)
    }

    func series(library: LibraryIdentifier, sort: SeriesSortOrder, direction: SortDirection, filter: LibraryItemFilter?, page: Int, limit: Int) async throws -> Page<Series> {
        var query = Self.pageQuery(page: page, limit: limit) + [
            URLQueryItem(name: "sort", value: sort.rawValue),
            Self.flag("desc", direction.isDescending),
        ]
        if let filter = filter?.queryValue {
            query.append(URLQueryItem(name: "filter", value: filter))
        }
        let payload = try await fetch(PagedPayload<SeriesPayload>.self, APIRequest.get("api", "libraries", library.libraryID, "series", query: query).cached())
        let series = payload.results.map { converter.series($0, library: library.libraryID) }
        return Page(items: series, total: payload.total ?? series.count, page: page)
    }

    func authors(library: LibraryIdentifier, sort: AuthorSortOrder, direction: SortDirection, page: Int, limit: Int) async throws -> Page<Person> {
        let query = Self.pageQuery(page: page, limit: limit) + [
            URLQueryItem(name: "sort", value: sort.rawValue),
            Self.flag("desc", direction.isDescending),
        ]
        let payload = try await fetch(AuthorsResponsePayload.self, APIRequest.get("api", "libraries", library.libraryID, "authors", query: query).cached())
        let authors = payload.authors.map { converter.author($0, library: library.libraryID) }
        return Page(items: authors, total: payload.total ?? authors.count, page: page)
    }

    func narrators(library: LibraryIdentifier) async throws -> [Person] {
        let payload = try await fetch(NarratorsResponsePayload.self, APIRequest.get("api", "libraries", library.libraryID, "narrators").cached())
        return payload.narrators
            .map { converter.narrator($0, library: library.libraryID) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func collections(library: LibraryIdentifier, page: Int, limit: Int) async throws -> Page<ItemCollection> {
        try await groupings(library: library, endpoint: "collections", isPlaylist: false, page: page, limit: limit)
    }

    func playlists(library: LibraryIdentifier, page: Int, limit: Int) async throws -> Page<ItemCollection> {
        try await groupings(library: library, endpoint: "playlists", isPlaylist: true, page: page, limit: limit)
    }

    private func groupings(library: LibraryIdentifier, endpoint: String, isPlaylist: Bool, page: Int, limit: Int) async throws -> Page<ItemCollection> {
        let request = APIRequest.get("api", "libraries", library.libraryID, endpoint, query: Self.pageQuery(page: page, limit: limit)).cached()
        let payload = try await fetch(PagedPayload<CollectionPayload>.self, request)
        let items = payload.results.map { converter.collection($0, library: library.libraryID, isPlaylist: isPlaylist) }
        return Page(items: items, total: payload.total ?? items.count, page: page)
    }

    func search(library: LibraryIdentifier, query: String, limit: Int) async throws -> SearchResults {
        let request = APIRequest.get("api", "libraries", library.libraryID, "search", query: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
        ]).cached()
        let payload = try await fetch(SearchResponsePayload.self, request)
        return converter.searchResults(payload, library: library.libraryID)
    }

    /// Loads every audiobook matching `filter` (in server order when `sort` is `nil`).
    func allAudiobooks(library: String, filter: LibraryItemFilter, pageSize: Int = 100, maxPages: Int = 50) async throws -> [Audiobook] {
        var audiobooks: [Audiobook] = []
        for page in 0 ..< maxPages {
            let request = Self.itemsRequest(library: library, sort: nil, direction: .ascending, filter: filter, collapseSeries: false, page: page, limit: pageSize)
            let payload = try await fetch(PagedPayload<LibraryItemPayload>.self, request)
            audiobooks += payload.results.compactMap { converter.audiobook($0, library: library) }
            let total = payload.total ?? 0
            if payload.results.count < pageSize || audiobooks.count >= total {
                break
            }
        }
        return audiobooks
    }
}
