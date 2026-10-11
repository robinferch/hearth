import Foundation

/// Minimal audiobookshelf client used by UI tests to verify and prepare server state.
struct ServerAPI: Sendable {
    let host: URL
    let token: String

    struct Progress: Decodable, Sendable {
        let id: String
        let libraryItemId: String
        let episodeId: String?
        let currentTime: Double
        let progress: Double
        let isFinished: Bool
        let lastUpdate: Double
    }

    struct Bookmark: Decodable, Sendable {
        let libraryItemId: String
        let title: String
        let time: Double
        let createdAt: Double
    }

    struct Me: Decodable, Sendable {
        let id: String
        let mediaProgress: [Progress]
        let bookmarks: [Bookmark]
    }

    struct Session: Decodable, Sendable {
        let id: String
        let libraryItemId: String
        let episodeId: String?
        let currentTime: Double
        let timeListening: Double?
        let updatedAt: Double
    }

    struct LibraryItem: Decodable, Sendable {
        let id: String
        let libraryId: String
        let media: Media

        struct Media: Decodable, Sendable {
            let metadata: Metadata
            let episodes: [Episode]?
            let chapters: [Chapter]?
        }

        struct Chapter: Decodable, Sendable {
            let start: Double
            let end: Double
            let title: String
        }

        struct Metadata: Decodable, Sendable {
            let title: String?
        }

        struct Episode: Decodable, Sendable {
            let id: String
            let title: String
            let duration: Double?
            let publishedAt: Double?
        }
    }

    enum Failure: Error {
        case status(Int, String)
    }

    static func login(host: String, username: String, password: String) async throws -> ServerAPI {
        let url = URL(string: host)!
        struct Response: Decodable {
            struct User: Decodable {
                let accessToken: String?
                let token: String?
            }
            let user: User
        }
        var request = URLRequest(url: url.appending(path: "login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["username": username, "password": password])
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
        let user = try JSONDecoder().decode(Response.self, from: data).user
        return ServerAPI(host: url, token: user.accessToken ?? user.token ?? "")
    }

    // MARK: Requests

    func send(_ path: String, method: String = "GET", body: Any? = nil) async throws -> Data {
        // `appending(path:)` would percent-encode the query.
        var request = URLRequest(url: URL(string: path, relativeTo: host)!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data)
        return data
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure.status(status, String(decoding: data, as: UTF8.self))
        }
    }

    // MARK: Queries

    func me() async throws -> Me {
        try JSONDecoder().decode(Me.self, from: try await send("api/me"))
    }

    func progress(itemID: String, episodeID: String? = nil) async throws -> Progress? {
        try await me().mediaProgress.first { $0.libraryItemId == itemID && $0.episodeId == episodeID }
    }

    func bookmarks(itemID: String) async throws -> [Bookmark] {
        try await me().bookmarks.filter { $0.libraryItemId == itemID }
    }

    func sessions() async throws -> [Session] {
        struct Response: Decodable { let sessions: [Session] }
        return try JSONDecoder().decode(Response.self, from: try await send("api/me/listening-sessions?itemsPerPage=50")).sessions
    }

    /// Library items of all libraries keyed by title.
    func items() async throws -> [String: LibraryItem] {
        struct Libraries: Decodable {
            struct Library: Decodable { let id: String }
            let libraries: [Library]
        }
        struct Page: Decodable { let results: [LibraryItem] }
        var result: [String: LibraryItem] = [:]
        let libraries = try JSONDecoder().decode(Libraries.self, from: try await send("api/libraries")).libraries
        for library in libraries {
            let page = try JSONDecoder().decode(Page.self, from: try await send("api/libraries/\(library.id)/items?limit=200"))
            for item in page.results {
                result[item.media.metadata.title ?? item.id] = item
            }
        }
        return result
    }

    func item(_ id: String) async throws -> LibraryItem {
        try JSONDecoder().decode(LibraryItem.self, from: try await send("api/items/\(id)?expanded=1"))
    }

    // MARK: Mutations

    func setProgress(itemID: String, episodeID: String? = nil, body: [String: Any]) async throws {
        let path = episodeID.map { "api/me/progress/\(itemID)/\($0)" } ?? "api/me/progress/\(itemID)"
        _ = try await send(path, method: "PATCH", body: body)
    }

    /// Removes all progress and bookmarks of `itemID` for the test account.
    func resetItem(_ itemID: String) async throws {
        let me = try await me()
        for progress in me.mediaProgress where progress.libraryItemId == itemID {
            _ = try await send("api/me/progress/\(progress.id)", method: "DELETE")
        }
        for bookmark in me.bookmarks where bookmark.libraryItemId == itemID {
            _ = try await send("api/me/item/\(itemID)/bookmark/\(Int(bookmark.time))", method: "DELETE")
        }
    }

    /// ItemIdentifier string as used by Hearth (`TYPE::CONNECTION::LIBRARY::PRIMARY[::GROUPING]`) is built by the
    /// app; tests use titles for navigation and server ids for verification.
    func itemID(title: String) async throws -> String {
        guard let item = try await items()[title] else { throw Failure.status(404, "No item titled \(title)") }
        return item.id
    }
}
