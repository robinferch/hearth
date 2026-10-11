import Foundation
import HearthModel

// MARK: Collections & playlists

extension APIClient {
    func createCollection(name: String, library: LibraryIdentifier, items: [ItemIdentifier], playlist: Bool) async throws -> ItemIdentifier {
        let request: APIRequest
        if playlist {
            request = try APIRequest.post("api", "playlists").json(CreatePlaylistBody(name: name, libraryId: library.libraryID, items: items.map(PlaylistItemBody.init)))
        } else {
            request = try APIRequest.post("api", "collections").json(CreateCollectionBody(name: name, libraryId: library.libraryID, books: items.map(\.apiItemID)))
        }
        let created = try await fetch(IdentifiedPayload.self, request)
        return converter.identifier(playlist ? .playlist : .collection, library: library.libraryID, primary: created.id)
    }

    func updateCollection(_ id: ItemIdentifier, name: String?, description: String?, items: [ItemIdentifier]?) async throws {
        let request: APIRequest
        if id.kind == .playlist {
            request = try APIRequest.patch("api", "playlists", id.primaryID).json(UpdatePlaylistBody(name: name, description: description, items: items?.map(PlaylistItemBody.init))).idempotent()
        } else {
            request = try APIRequest.patch("api", "collections", id.primaryID).json(UpdateCollectionBody(name: name, description: description, books: items?.map(\.apiItemID))).idempotent()
        }
        try await perform(request)
    }

    func addToCollection(_ id: ItemIdentifier, items: [ItemIdentifier]) async throws {
        try await batch(id, items: items, action: "add")
    }

    func removeFromCollection(_ id: ItemIdentifier, items: [ItemIdentifier]) async throws {
        try await batch(id, items: items, action: "remove")
    }

    private func batch(_ id: ItemIdentifier, items: [ItemIdentifier], action: String) async throws {
        guard !items.isEmpty else { return }
        let request: APIRequest
        if id.kind == .playlist {
            request = try APIRequest.post("api", "playlists", id.primaryID, "batch", action).json(PlaylistItemsBody(items: items.map(PlaylistItemBody.init)))
        } else {
            request = try APIRequest.post("api", "collections", id.primaryID, "batch", action).json(CollectionBooksBody(books: items.map(\.apiItemID)))
        }
        try await perform(request)
    }

    func deleteCollection(_ id: ItemIdentifier) async throws {
        try await perform(APIRequest.delete("api", id.kind == .playlist ? "playlists" : "collections", id.primaryID).idempotent())
    }

    func createPlaylist(fromCollection id: ItemIdentifier) async throws -> ItemIdentifier {
        let created = try await fetch(IdentifiedPayload.self, .post("api", "playlists", "collection", id.primaryID))
        return converter.identifier(.playlist, library: id.libraryID, primary: created.id)
    }
}
