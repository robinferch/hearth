import Foundation
import HearthModel

// MARK: Single items

extension APIClient {
    /// `GET api/items/{id}?expanded=1`, optionally with the user's progress (of `episodeID` for podcasts).
    func expandedItem(_ itemID: String, includeProgress: Bool = false, episodeID: String? = nil, cached: Bool = false) async throws -> LibraryItemPayload {
        var query = [URLQueryItem(name: "expanded", value: "1")]
        if includeProgress {
            query.append(URLQueryItem(name: "include", value: "progress"))
            if let episodeID {
                query.append(URLQueryItem(name: "episode", value: episodeID))
            }
        }
        var request = APIRequest.get("api", "items", itemID, query: query)
        if cached {
            request = request.cached()
        }
        return try await fetch(LibraryItemPayload.self, request)
    }

    func audiobook(_ id: ItemIdentifier) async throws -> Audiobook {
        let item = try await expandedItem(id.apiItemID)
        guard let audiobook = converter.audiobook(item, library: id.libraryID) else {
            throw APIError.notFound
        }
        return audiobook
    }

    func podcast(_ id: ItemIdentifier) async throws -> (podcast: Podcast, episodes: [Episode]) {
        let item = try await expandedItem(id.apiItemID)
        guard let podcast = converter.podcast(item, library: id.libraryID) else {
            throw APIError.notFound
        }
        return (podcast, converter.episodes(of: item, library: id.libraryID))
    }

    func episode(_ id: ItemIdentifier) async throws -> Episode {
        guard let episodeID = id.apiEpisodeID else {
            throw APIError.notFound
        }
        // The single-episode endpoint lacks the podcast name; the (briefly cached) podcast item has everything.
        let item = try await expandedItem(id.apiItemID, cached: true)
        guard let payload = item.media?.episodes.first(where: { $0.id == episodeID }),
              let episode = converter.episode(payload, podcastItem: item, library: id.libraryID) else {
            throw APIError.notFound
        }
        return episode
    }

    func playableDetails(_ id: ItemIdentifier) async throws -> PlayableItemDetails {
        let item = try await expandedItem(id.apiItemID, includeProgress: true, episodeID: id.apiEpisodeID)
        guard let details = converter.playableDetails(item, episodeID: id.apiEpisodeID, library: id.libraryID) else {
            throw APIError.notFound
        }
        return details
    }

    func author(_ id: ItemIdentifier) async throws -> (author: Person, audiobooks: [Audiobook], series: [Series]) {
        let request = APIRequest.get("api", "authors", id.primaryID, query: [URLQueryItem(name: "include", value: "items,series")])
        let payload = try await fetch(AuthorPayload.self, request)
        let libraryID = payload.libraryID ?? id.libraryID
        let author = converter.author(payload, library: libraryID)
        let audiobooks = payload.libraryItems.compactMap { converter.audiobook($0, library: libraryID) }
        let series = payload.series.map { group in
            let books = group.items.compactMap { converter.audiobook($0, library: libraryID) }
            return Series(id: converter.identifier(.series, library: libraryID, primary: group.id), name: group.name, audiobooks: books)
        }
        return (author, audiobooks, series)
    }

    func narrator(_ id: ItemIdentifier) async throws -> (narrator: Person, audiobooks: [Audiobook]) {
        let name = PayloadConverter.narratorName(primaryID: id.primaryID)
        let audiobooks = try await allAudiobooks(library: id.libraryID, filter: .narrator(name: name))
        let narrator = converter.narrator(name: name, bookCount: audiobooks.count, library: id.libraryID)
        return (narrator, audiobooks)
    }

    func seriesDetails(_ id: ItemIdentifier) async throws -> Series {
        async let metadata = fetch(SeriesPayload.self, .get("api", "libraries", id.libraryID, "series", id.primaryID))
        let audiobooks = try await allAudiobooks(library: id.libraryID, filter: .series(id: id.primaryID))

        do {
            var series = converter.series(try await metadata, library: id.libraryID)
            series.audiobooks = audiobooks
            series.bookCount = audiobooks.count
            return series
        } catch APIError.notFound where !audiobooks.isEmpty {
            // Older servers lack the single-series endpoint; derive the name from the books.
            let name = audiobooks.lazy.flatMap(\.series).first { $0.id == id.primaryID }?.name ?? audiobooks[0].series.first?.name ?? ""
            return Series(id: converter.identifier(.series, library: id.libraryID, primary: id.primaryID), name: name, audiobooks: audiobooks)
        }
    }

    func collection(_ id: ItemIdentifier) async throws -> ItemCollection {
        let isPlaylist = id.kind == .playlist
        let payload = try await fetch(CollectionPayload.self, .get("api", isPlaylist ? "playlists" : "collections", id.primaryID))
        return converter.collection(payload, library: id.libraryID, isPlaylist: isPlaylist)
    }

    func updateEpisodeType(_ id: ItemIdentifier, type: Episode.EpisodeType) async throws {
        guard let podcastID = id.groupingID else {
            throw APIError.notFound
        }
        try await perform(APIRequest.patch("api", "podcasts", podcastID, "episode", id.primaryID).json(EpisodeTypeBody(episodeType: type.rawValue)).idempotent())
    }
}
