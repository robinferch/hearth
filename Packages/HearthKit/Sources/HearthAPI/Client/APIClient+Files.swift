import Foundation
import HearthModel

// MARK: Files & URLs

extension APIClient {
    func coverRequest(for id: ItemIdentifier, size: ImageSize) async throws -> URLRequest {
        let query = [URLQueryItem(name: "width", value: String(size.width))]
        let request: APIRequest
        switch id.kind {
        case .author:
            request = .get("api", "authors", id.primaryID, "image", query: query)
        case .audiobook, .podcast, .episode:
            request = .get("api", "items", id.apiItemID, "cover", query: query)
        case .narrator, .series, .collection, .playlist:
            throw APIError.notFound
        }
        return try await executor.urlRequest(for: request)
    }

    func audioFileRequest(for id: ItemIdentifier, ino: String) async throws -> URLRequest {
        var request = APIRequest.get("api", "items", id.apiItemID, "file", ino, "download")
        request.timeout = 120
        return try await executor.urlRequest(for: request)
    }

    func pdfRequest(for id: ItemIdentifier, ino: String) async throws -> URLRequest {
        var request = APIRequest.get("api", "items", id.apiItemID, "ebook", ino)
        request.timeout = 120
        return try await executor.urlRequest(for: request)
    }

    func streamingHeaders() async throws -> [String: String] {
        await executor.authorizationHeaders()
    }

    func refreshAuthorization(rejectedRequest: URLRequest) async throws {
        try await executor.refreshAfterRejection(of: JWT.bearerToken(in: rejectedRequest.value(forHTTPHeaderField: "Authorization")))
    }

    func webURL(for id: ItemIdentifier) -> URL {
        let path: [String]
        switch id.kind {
        case .audiobook, .podcast:
            path = ["item", id.primaryID]
        case .episode:
            path = ["item", id.apiItemID]
        case .author:
            path = ["author", id.primaryID]
        case .series:
            path = ["library", id.libraryID, "series", id.primaryID]
        case .collection:
            path = ["collection", id.primaryID]
        case .playlist:
            path = ["playlist", id.primaryID]
        case .narrator:
            let filter = LibraryItemFilter.narrator(name: PayloadConverter.narratorName(primaryID: id.primaryID)).queryValue
            return (try? URLBuilder.url(host: connection.host, path: ["library", id.libraryID, "bookshelf"], query: [URLQueryItem(name: "filter", value: filter)])) ?? connection.host
        }
        return (try? URLBuilder.url(host: connection.host, path: path)) ?? connection.host
    }
}
