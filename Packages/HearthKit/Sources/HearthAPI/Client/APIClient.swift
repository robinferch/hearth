import Foundation
import HearthModel
import os

/// Production `AudiobookshelfClient` for one connection.
///
/// All mutable state lives in actors (`RequestExecutor`, `SocketIOClient`) or lock-protected helpers, so the
/// client itself is an immutable `Sendable` value holder.
final class APIClient: AudiobookshelfClient {
    let connection: Connection
    let executor: RequestExecutor
    let converter: PayloadConverter
    let resolver: LibraryResolver
    let broadcaster = EventBroadcaster<ServerEvent>()
    let socket: SocketIOClient

    let logger = Logger.api(APIClient.self)

    convenience init(connection: Connection, tokenStore: any TokenStore, delegate: (any APIClientDelegate)?) {
        self.init(connection: connection, tokenStore: tokenStore, delegate: delegate, configuration: RequestExecutor.Configuration())
    }

    init(connection: Connection, tokenStore: any TokenStore, delegate: (any APIClientDelegate)?, configuration: RequestExecutor.Configuration) {
        self.connection = connection
        let executor = RequestExecutor(connection: connection, tokenStore: tokenStore, delegate: delegate, configuration: configuration)
        let converter = PayloadConverter(connectionID: connection.id, host: connection.host)
        let resolver = LibraryResolver(executor: executor, directory: converter.directory)
        let mapper = ServerEventMapper(converter: converter, resolver: resolver, executor: executor, broadcaster: broadcaster)

        self.executor = executor
        self.converter = converter
        self.resolver = resolver
        self.socket = SocketIOClient(
            configuration: SocketIOClient.Configuration(
                host: connection.host,
                headers: connection.headers,
                pinnedSHA256: connection.pinnedCertificateSHA256,
                identityID: connection.id
            ),
            session: executor.session,
            tokenProvider: { await executor.accessToken() },
            authFailed: { token in try? await executor.refreshAfterRejection(of: token) },
            handler: { event in await mapper.handle(event) }
        )
    }

    deinit {
        broadcaster.finish()
    }

    // MARK: Request helpers

    func fetch<T: Decodable>(_ type: T.Type, _ request: APIRequest) async throws -> T {
        let data = try await executor.data(for: request)
        do {
            return try JSONDecoder.api.decode(T.self, from: data)
        } catch {
            logger.error("Decoding \(String(describing: T.self), privacy: .public) from \(request.path.joined(separator: "/"), privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw APIError.decoding(String(describing: error))
        }
    }

    func perform(_ request: APIRequest) async throws {
        _ = try await executor.data(for: request)
    }

    static func pageQuery(page: Int, limit: Int) -> [URLQueryItem] {
        [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "page", value: String(page))]
    }

    static func flag(_ name: String, _ value: Bool) -> URLQueryItem {
        URLQueryItem(name: name, value: value ? "1" : "0")
    }

    // MARK: Account

    func me() async throws -> (userID: String, username: String) {
        let user = try await fetch(UserPayload.self, .get("api", "me"))
        return (user.id, user.username)
    }

    func authorize() async throws -> AuthorizeResponse {
        // Read-only despite being a POST.
        var request = APIRequest.post("api", "authorize").idempotent()
        request.bypassesLimiter = true
        let user = try await fetch(UserResponsePayload.self, request).user

        await resolver.resolve(user.mediaProgress.map(\.libraryItemID) + user.bookmarks.map(\.libraryItemID))

        let progress = user.mediaProgress.compactMap(converter.progress)
        let bookmarks = user.bookmarks.compactMap(converter.bookmark)
        let dropped = user.mediaProgress.count - progress.count + user.bookmarks.count - bookmarks.count
        if dropped > 0 {
            logger.info("Skipped \(dropped) progress/bookmark entries of items that no longer exist")
        }
        return AuthorizeResponse(userID: user.id, username: user.username, progress: progress, bookmarks: bookmarks)
    }

    // MARK: Live updates

    func events() -> AsyncStream<ServerEvent> {
        broadcaster.stream()
    }

    func connectSocket() async {
        guard !APINetworkPolicy.shared.isOffline else { return }
        await socket.connect()
    }

    func disconnectSocket() async {
        await socket.disconnect()
    }
}

/// Resolves the library of library item ids that were never seen in a list response.
struct LibraryResolver: Sendable {
    let executor: RequestExecutor
    let directory: LibraryItemDirectory
    private static let batchSize = 50

    func resolve(_ itemIDs: [String]) async {
        let unknown = directory.unknown(itemIDs)
        guard !unknown.isEmpty else { return }

        for start in stride(from: 0, to: unknown.count, by: Self.batchSize) {
            let chunk = Array(unknown[start ..< min(start + Self.batchSize, unknown.count)])
            do {
                let request = try APIRequest.post("api", "items", "batch", "get").json(BatchGetBody(libraryItemIds: chunk)).idempotent()
                let data = try await executor.data(for: request)
                let payload = try JSONDecoder.api.decode(BatchItemsPayload.self, from: data)
                register(payload.libraryItems)
            } catch {
                // The batch fails as a whole if a single item is inaccessible; fall back to individual lookups.
                await resolveIndividually(chunk)
            }
        }
    }

    private func resolveIndividually(_ itemIDs: [String]) async {
        await withTaskGroup(of: LibraryItemPayload?.self) { group in
            for itemID in itemIDs {
                group.addTask {
                    guard let data = try? await executor.data(for: .get("api", "items", itemID)) else { return nil }
                    return try? JSONDecoder.api.decode(LibraryItemPayload.self, from: data)
                }
            }
            for await item in group {
                if let item {
                    register([item])
                }
            }
        }
    }

    private func register(_ items: [LibraryItemPayload]) {
        for item in items {
            if let libraryID = item.libraryID {
                directory.register(itemID: item.id, libraryID: libraryID, isPodcast: item.isPodcast)
            }
        }
    }
}
