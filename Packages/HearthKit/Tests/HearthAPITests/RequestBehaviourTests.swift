import Foundation
import HearthModel
import Testing
@testable import HearthAPI

/// Network tests share `APINetworkPolicy.shared` and run serially.
@Suite(.serialized) enum NetworkTests {}

extension NetworkTests {
@Suite struct RequestBehaviourTests {
    @Test func buildsAuthorizedRequestsWithSubPathAndSortedHeaders() async throws {
        let harness = ClientHarness(path: "/abs", headers: [HTTPHeader(key: "X-B", value: "2"), HTTPHeader(key: "X-A", value: "1")]) { _ in
            .fixture("libraries")
        }
        let libraries = try await harness.client.libraries()
        #expect(libraries.map(\.name) == ["Audiobooks", "Podcasts"])

        let request = try #require(harness.requests.first)
        #expect(request.path == "/abs/api/libraries")
        #expect(request.header("Authorization") == "Bearer access-1")
        #expect(request.header("X-A") == "1")
        #expect(request.header("X-B") == "2")
    }

    @Test func sendsJSONBodies() async throws {
        let harness = ClientHarness { _ in .json("{}") }
        let id = ItemIdentifier(kind: .audiobook, connectionID: harness.connection.id, libraryID: "lib", primaryID: "li_1")
        try await harness.client.updateBookmark(id, time: 42, note: "Note")

        let request = try #require(harness.requests.first)
        #expect(request.method == "PATCH")
        #expect(request.path == "/api/me/item/li_1/bookmark")
        #expect(request.header("Content-Type") == "application/json")
        let body = try #require(request.jsonBody as? [String: Any])
        #expect(body["title"] as? String == "Note")
        #expect(body["time"] as? Int == 42)
    }

    @Test func retriesServerErrorsUpToThreeAttempts() async throws {
        let counter = Counter()
        let harness = ClientHarness { _ in
            counter.increment() < 3 ? .status(502) : .fixture("libraries")
        }
        let libraries = try await harness.client.libraries()
        #expect(libraries.count == 2)
        #expect(counter.current == 3)
    }

    @Test func givesUpAfterThreeAttempts() async throws {
        let counter = Counter()
        let harness = ClientHarness { _ in
            counter.increment()
            return MockResponse(error: URLError(.networkConnectionLost))
        }
        await #expect(throws: APIError.unreachable) {
            try await harness.client.libraries()
        }
        #expect(counter.current == 3)
    }

    @Test func doesNotRetryNonIdempotentMutations() async throws {
        let counter = Counter()
        let harness = ClientHarness { request in
            // Count only the mutations; the local session upload may look up the item title first.
            if request.method != "GET" {
                counter.increment()
            }
            return MockResponse(error: URLError(.timedOut))
        }
        let library = LibraryIdentifier(connectionID: harness.connection.id, libraryID: "lib")
        let book = ItemIdentifier(kind: .audiobook, connectionID: harness.connection.id, libraryID: "lib", primaryID: "li")
        let device = DeviceInfo(deviceID: "dev", clientVersion: "1.0", model: "iPhone", osName: "iOS", osVersion: "26.0")

        await #expect(throws: APIError.unreachable) {
            try await harness.client.createCollection(name: "Mix", library: library, items: [book], playlist: false)
        }
        await #expect(throws: APIError.unreachable) {
            try await harness.client.startSession(book, device: device)
        }
        await #expect(throws: APIError.unreachable) {
            let upload = LocalSessionUpload(itemID: book, startTime: 0, currentTime: 10, duration: 100, timeListened: 10, startedAt: .now, updatedAt: .now)
            try await harness.client.uploadLocalSession(upload, device: device)
        }
        #expect(counter.current == 3)
    }

    @Test func retriesIdempotentMutations() async throws {
        let counter = Counter()
        let harness = ClientHarness { _ in
            // Every request fails twice before succeeding.
            counter.increment() % 3 == 0 ? .json("{}") : .status(503)
        }
        let book = ItemIdentifier(kind: .audiobook, connectionID: harness.connection.id, libraryID: "lib", primaryID: "li")
        try await harness.client.batchUpdateProgress([ProgressEntity(id: "p", itemID: book, progress: 0.5, duration: 10, currentTime: 5, startedAt: nil, lastUpdate: .now, finishedAt: nil)])
        #expect(counter.current == 3)
        try await harness.client.syncSession("s1", currentTime: 5, duration: 10, timeListened: 1)
        #expect(counter.current == 6)
    }

    @Test func doesNotRetryNotFound() async throws {
        let counter = Counter()
        let harness = ClientHarness { _ in
            counter.increment()
            return .status(404)
        }
        let id = ItemIdentifier(kind: .audiobook, connectionID: harness.connection.id, libraryID: "lib", primaryID: "missing")
        await #expect(throws: APIError.notFound) {
            try await harness.client.audiobook(id)
        }
        #expect(counter.current == 1)
    }

    @Test func refreshesTokenOn401AndRetries() async throws {
        let harness = ClientHarness { request in
            if request.path == "/auth/refresh" {
                guard request.header("x-refresh-token") == "refresh-1", request.header("Authorization") == nil else {
                    return .status(401)
                }
                return .json(#"{"user":{"id":"usr_1","username":"robin","accessToken":"access-2","refreshToken":"refresh-2"}}"#)
            }
            return request.header("Authorization") == "Bearer access-2" ? .fixture("libraries") : .status(401)
        }

        let libraries = try await harness.client.libraries()
        #expect(libraries.count == 2)
        #expect(await harness.tokenStore.tokens(for: harness.connection.id) == AuthTokens(accessToken: "access-2", refreshToken: "refresh-2"))
        #expect(harness.requests.map(\.path) == ["/api/libraries", "/auth/refresh", "/api/libraries"])
        #expect(harness.delegate.unauthorizedConnections.isEmpty)
    }

    @Test func concurrent401sShareOneRefresh() async throws {
        let refreshes = Counter()
        let harness = ClientHarness { request in
            if request.path == "/auth/refresh" {
                refreshes.increment()
                var response = MockResponse.json(#"{"user":{"id":"usr_1","username":"robin","accessToken":"access-2","refreshToken":"refresh-2"}}"#)
                response.delay = .milliseconds(100)
                return response
            }
            return request.header("Authorization") == "Bearer access-2" ? .json("{}") : .status(401)
        }

        let connectionID = harness.connection.id
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< 5 {
                group.addTask {
                    let id = ItemIdentifier(kind: .audiobook, connectionID: connectionID, libraryID: "lib", primaryID: "li_\(index)")
                    try await harness.client.setFinished(id, finished: true)
                }
            }
            try await group.waitForAll()
        }
        #expect(refreshes.current == 1)
    }

    @Test func refreshFailureNotifiesDelegateAndFailsFast() async throws {
        let counter = Counter()
        let harness = ClientHarness { request in
            counter.increment()
            return request.path == "/auth/refresh" ? .json(#"{"error":"Invalid refresh token"}"#, status: 401) : .status(401)
        }

        await #expect(throws: APIError.unauthorized) {
            try await harness.client.libraries()
        }
        #expect(harness.delegate.unauthorizedConnections == [harness.connection.id])
        let requestsAfterFailure = counter.current

        // Further requests fail without hitting the network until new tokens are stored.
        await #expect(throws: APIError.unauthorized) {
            try await harness.client.narrators(library: LibraryIdentifier(connectionID: harness.connection.id, libraryID: "lib"))
        }
        #expect(counter.current == requestsAfterFailure)
        #expect(harness.delegate.unauthorizedConnections.count == 1)
    }

    @Test func legacyTokenWithoutRefreshTokenBecomesUnauthorized() async throws {
        let harness = ClientHarness(tokens: AuthTokens(accessToken: "legacy", refreshToken: nil)) { _ in .status(401) }
        await #expect(throws: APIError.unauthorized) {
            try await harness.client.me()
        }
        #expect(harness.delegate.unauthorizedConnections.count == 1)
        #expect(!harness.requests.contains { $0.path == "/auth/refresh" })
    }

    static func jwt(expiresIn seconds: TimeInterval) -> String {
        func encode(_ json: String) -> String {
            Data(json.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let exp = Int(Date.now.timeIntervalSince1970 + seconds)
        return "\(encode(#"{"alg":"HS256","typ":"JWT"}"#)).\(encode(#"{"userId":"usr_1","type":"access","exp":\#(exp)}"#)).signature"
    }

    static func refreshingServer(refreshes: Counter) -> MockURLProtocol.Handler {
        { request in
            if request.path == "/auth/refresh" {
                refreshes.increment()
                return .json(#"{"user":{"id":"usr_1","username":"robin","accessToken":"access-2","refreshToken":"refresh-2"}}"#)
            }
            return .json("{}")
        }
    }

    @Test func parsesJWTExpiry() throws {
        let expiry = try #require(JWT.expiry(of: Self.jwt(expiresIn: 3600)))
        #expect(abs(expiry.timeIntervalSinceNow - 3600) < 5)
        #expect(JWT.expiry(of: "legacy-token") == nil)
        #expect(JWT.bearerToken(in: "Bearer abc") == "abc")
        #expect(JWT.bearerToken(in: nil) == nil)
    }

    @Test func handedOutRequestsRefreshTokensAboutToExpire() async throws {
        let refreshes = Counter()
        let harness = ClientHarness(tokens: AuthTokens(accessToken: Self.jwt(expiresIn: 120), refreshToken: "refresh-1"), handler: Self.refreshingServer(refreshes: refreshes))
        let book = ItemIdentifier(kind: .audiobook, connectionID: harness.connection.id, libraryID: "lib", primaryID: "li")

        // Downloads may start long after the request was built: a token valid for two more minutes is renewed.
        let request = try await harness.client.audioFileRequest(for: book, ino: "1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-2")
        #expect(try await harness.client.streamingHeaders()["Authorization"] == "Bearer access-2")
        #expect(refreshes.current == 1)
    }

    @Test func validTokensAreNotRefreshedEarly() async throws {
        let refreshes = Counter()
        let token = Self.jwt(expiresIn: 3600)
        let harness = ClientHarness(tokens: AuthTokens(accessToken: token, refreshToken: "refresh-1"), handler: Self.refreshingServer(refreshes: refreshes))
        let book = ItemIdentifier(kind: .audiobook, connectionID: harness.connection.id, libraryID: "lib", primaryID: "li")
        #expect(try await harness.client.coverRequest(for: book, size: .large).value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        try await harness.client.setFinished(book, finished: true)
        #expect(refreshes.current == 0)
    }

    @Test func expiredTokensAreRefreshedBeforeSending() async throws {
        let refreshes = Counter()
        let harness = ClientHarness(tokens: AuthTokens(accessToken: Self.jwt(expiresIn: -10), refreshToken: "refresh-1"), handler: Self.refreshingServer(refreshes: refreshes))
        let book = ItemIdentifier(kind: .audiobook, connectionID: harness.connection.id, libraryID: "lib", primaryID: "li")
        try await harness.client.setFinished(book, finished: true)
        #expect(harness.requests.map(\.path) == ["/auth/refresh", "/api/me/progress/li"])
        #expect(harness.requests.last?.header("Authorization") == "Bearer access-2")
    }

    @Test func rejectedHandedOutRequestRefreshesOnce() async throws {
        let refreshes = Counter()
        let harness = ClientHarness(handler: Self.refreshingServer(refreshes: refreshes))
        let book = ItemIdentifier(kind: .audiobook, connectionID: harness.connection.id, libraryID: "lib", primaryID: "li")
        let rejected = try await harness.client.audioFileRequest(for: book, ino: "1")
        #expect(rejected.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")

        try await harness.client.refreshAuthorization(rejectedRequest: rejected)
        // A second task rejected with the same old token doesn't refresh again.
        try await harness.client.refreshAuthorization(rejectedRequest: rejected)
        #expect(refreshes.current == 1)
        #expect(try await harness.client.audioFileRequest(for: book, ino: "1").value(forHTTPHeaderField: "Authorization") == "Bearer access-2")
    }

    @Test func deduplicatesIdenticalInFlightGets() async throws {
        let counter = Counter()
        let harness = ClientHarness { _ in
            counter.increment()
            var response = MockResponse.fixture("libraries")
            response.delay = .milliseconds(150)
            return response
        }
        async let first = harness.client.libraries()
        async let second = harness.client.libraries()
        async let third = harness.client.libraries()
        let results = try await [first, second, third]
        #expect(results.allSatisfy { $0.count == 2 })
        #expect(counter.current == 1)
    }

    @Test func cachesListResponsesUntilMutation() async throws {
        let counter = Counter()
        let harness = ClientHarness { request in
            if request.method == "GET" {
                counter.increment()
                return .fixture("libraries")
            }
            return .json("{}")
        }
        _ = try await harness.client.libraries()
        _ = try await harness.client.libraries()
        #expect(counter.current == 1)

        try await harness.client.deleteProgress(id: "mp_1")
        _ = try await harness.client.libraries()
        #expect(counter.current == 2)
    }

    @Test func offlineModeBlocksRequests() async throws {
        let harness = ClientHarness { _ in .fixture("libraries") }
        APINetworkPolicy.shared.isOffline = true
        defer { APINetworkPolicy.shared.isOffline = false }
        await #expect(throws: APIError.offline) {
            try await harness.client.libraries()
        }
        #expect(harness.requests.isEmpty)
    }

    @Test func authorizeResolvesUnknownLibrariesViaBatchGet() async throws {
        let harness = ClientHarness { request in
            switch request.path {
            case "/api/authorize": .fixture("authorize")
            case "/api/items/batch/get": .fixture("batch-get")
            default: .status(404)
            }
        }
        let response = try await harness.client.authorize()
        #expect(response.userID == "usr_1")
        #expect(response.progress.map(\.id) == ["mp_book1", "mp_ep1"])
        #expect(response.bookmarks.count == 1)

        let batch = try #require(harness.requests.first { $0.path == "/api/items/batch/get" })
        let ids = try #require((batch.jsonBody as? [String: Any])?["libraryItemIds"] as? [String])
        #expect(Set(ids) == ["li_book1", "li_pod1", "li_deleted"])
    }

    @Test func authorizeReportsItemsThatCouldNotBeLookedUp() async throws {
        let harness = ClientHarness { request in
            switch request.path {
            case "/api/authorize": .fixture("authorize")
            case "/api/items/li_pod1": .fixture("item-podcast-expanded")
            case "/api/items/li_deleted": .status(404)
            default: .status(500)
            }
        }
        let response = try await harness.client.authorize()
        // li_book1 failed (server error): still on the server, must not be treated as deleted. li_deleted is gone.
        #expect(response.unresolvedItemIDs == ["li_book1"])
        #expect(response.progress.map(\.id) == ["mp_ep1"])
    }

    @Test func startSessionSendsDeviceInfoAndReturnsAbsoluteTracks() async throws {
        let harness = ClientHarness(path: "/abs") { _ in .fixture("session-play") }
        let id = ItemIdentifier(kind: .episode, connectionID: harness.connection.id, libraryID: "lib_pods", primaryID: "ep_1", groupingID: "li_pod1")
        let device = DeviceInfo(deviceID: "dev", clientVersion: "1.0", model: "iPhone17,1", osName: "iOS", osVersion: "26.0")
        let session = try await harness.client.startSession(id, device: device)

        let request = try #require(harness.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/abs/api/items/li_pod1/play/ep_1")
        let body = try #require(request.jsonBody as? [String: Any])
        #expect(body["mediaPlayer"] as? String == "AVPlayer")
        #expect(body["forceDirectPlay"] as? Bool == true)
        #expect((body["supportedMimeTypes"] as? [String])?.contains("audio/x-m4b") == true)
        #expect((body["deviceInfo"] as? [String: Any])?["deviceId"] as? String == "dev")
        #expect((body["deviceInfo"] as? [String: Any])?["clientName"] as? String == "Hearth")

        #expect(session.tracks.first?.url.absoluteString == "https://\(harness.host.host()!)/abs/api/items/li_pod1/file/101")
    }

    @Test func fileRequestsAreAuthorized() async throws {
        let harness = ClientHarness(path: "/abs", headers: [HTTPHeader(key: "CF-Access", value: "secret")]) { _ in .json("{}") }
        let episode = ItemIdentifier(kind: .episode, connectionID: harness.connection.id, libraryID: "lib", primaryID: "ep", groupingID: "li_pod")
        let cover = try await harness.client.coverRequest(for: episode, size: .regular)
        #expect(cover.url?.path() == "/abs/api/items/li_pod/cover")
        #expect(cover.url?.query() == "width=600")
        #expect(cover.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
        #expect(cover.value(forHTTPHeaderField: "CF-Access") == "secret")

        let author = ItemIdentifier(kind: .author, connectionID: harness.connection.id, libraryID: "lib", primaryID: "aut")
        #expect(try await harness.client.coverRequest(for: author, size: .tiny).url?.path() == "/abs/api/authors/aut/image")

        let book = ItemIdentifier(kind: .audiobook, connectionID: harness.connection.id, libraryID: "lib", primaryID: "li")
        #expect(try await harness.client.audioFileRequest(for: book, ino: "123").url?.path() == "/abs/api/items/li/file/123/download")
        #expect(try await harness.client.pdfRequest(for: book, ino: "9").url?.path() == "/abs/api/items/li/ebook/9")

        let headers = try await harness.client.streamingHeaders()
        #expect(headers["Authorization"] == "Bearer access-1")
        #expect(headers["CF-Access"] == "secret")

        #expect(harness.client.webURL(for: book).absoluteString == "https://\(harness.host.host()!)/abs/item/li")
        let series = ItemIdentifier(kind: .series, connectionID: harness.connection.id, libraryID: "lib", primaryID: "ser")
        #expect(harness.client.webURL(for: series).absoluteString == "https://\(harness.host.host()!)/abs/library/lib/series/ser")
        #expect(harness.requests.isEmpty)
    }

    @Test func progressEndpoints() async throws {
        let harness = ClientHarness { _ in .json("{}") }
        let episode = ItemIdentifier(kind: .episode, connectionID: harness.connection.id, libraryID: "lib", primaryID: "ep", groupingID: "li")
        try await harness.client.setFinished(episode, finished: true)
        try await harness.client.hideFromContinueListening(progressID: "mp_1")
        try await harness.client.batchUpdateProgress([ProgressEntity(id: "p", itemID: episode, progress: 1, duration: 10, currentTime: 10, startedAt: nil, lastUpdate: Date(timeIntervalSince1970: 2), finishedAt: Date(timeIntervalSince1970: 2))])
        try await harness.client.deleteBookmark(ItemIdentifier(kind: .audiobook, connectionID: harness.connection.id, libraryID: "lib", primaryID: "li"), time: 12)

        let requests = harness.requests
        #expect(requests.map { "\($0.method) \($0.path)" } == [
            "PATCH /api/me/progress/li/ep",
            "GET /api/me/progress/mp_1/remove-from-continue-listening",
            "PATCH /api/me/progress/batch/update",
            "DELETE /api/me/item/li/bookmark/12",
        ])
        let batch = try #require(requests[2].jsonBody as? [[String: Any]])
        #expect(batch.first?["episodeId"] as? String == "ep")
        #expect(batch.first?["isFinished"] as? Bool == true)
        #expect(batch.first?["finishedAt"] as? Int == 2000)
    }

    /// Server (2.37) behaviour: bookmarks are matched on their exact stored time, `…/bookmark/123` doesn't find 123.6.
    static func fractionalBookmarkServer(_ request: RecordedRequest) -> MockResponse {
        let bookmarks = #"[{"libraryItemId":"li_1","time":123.6,"title":"Quote","createdAt":1700000000000}]"#
        switch (request.method, request.path) {
        case ("POST", "/api/authorize"):
            return .json(#"{"user":{"id":"usr_1","username":"robin","mediaProgress":[],"bookmarks":\#(bookmarks)}}"#)
        case ("GET", "/api/me"):
            return .json(#"{"id":"usr_1","username":"robin","mediaProgress":[],"bookmarks":\#(bookmarks)}"#)
        case ("DELETE", "/api/me/item/li_1/bookmark/123.6"):
            return .json("{}")
        case ("PATCH", "/api/me/item/li_1/bookmark"):
            return (request.jsonBody as? [String: Any])?["time"] as? Double == 123.6 ? .json("{}") : .status(404)
        default:
            return .status(404)
        }
    }

    @Test func bookmarkMutationsUseExactServerTime() async throws {
        let harness = ClientHarness(handler: Self.fractionalBookmarkServer)
        let id = ItemIdentifier(kind: .audiobook, connectionID: harness.connection.id, libraryID: "lib", primaryID: "li_1")
        _ = try await harness.client.authorize()

        try await harness.client.updateBookmark(id, time: 123, note: "Edited")
        let patch = try #require(harness.requests.last)
        #expect(patch.method == "PATCH")
        #expect((patch.jsonBody as? [String: Any])?["time"] as? Double == 123.6)
        #expect(harness.requests.filter { $0.method == "PATCH" }.count == 1)

        try await harness.client.deleteBookmark(id, time: 123)
        #expect(harness.requests.last?.path == "/api/me/item/li_1/bookmark/123.6")
    }

    @Test func bookmarkMutationResolvesUnknownFractionalTime() async throws {
        let harness = ClientHarness(handler: Self.fractionalBookmarkServer)
        let id = ItemIdentifier(kind: .audiobook, connectionID: harness.connection.id, libraryID: "lib", primaryID: "li_1")
        try await harness.client.deleteBookmark(id, time: 123)
        #expect(harness.requests.map { "\($0.method) \($0.path)" } == [
            "DELETE /api/me/item/li_1/bookmark/123",
            "GET /api/me",
            "DELETE /api/me/item/li_1/bookmark/123.6",
        ])

        // A bookmark that really doesn't exist still reports 404.
        await #expect(throws: APIError.notFound) {
            try await harness.client.deleteBookmark(id, time: 7)
        }
    }

    @Test func collectionMutations() async throws {
        let harness = ClientHarness { request in
            request.method == "POST" && request.path.hasSuffix("playlists") ? .json(#"{"id":"pl_new"}"#) : .json("{}")
        }
        let library = LibraryIdentifier(connectionID: harness.connection.id, libraryID: "lib")
        let episode = ItemIdentifier(kind: .episode, connectionID: harness.connection.id, libraryID: "lib", primaryID: "ep", groupingID: "li_pod")
        let id = try await harness.client.createCollection(name: "Mix", library: library, items: [episode], playlist: true)
        #expect(id.kind == .playlist)
        #expect(id.primaryID == "pl_new")
        try await harness.client.removeFromCollection(id, items: [episode])

        let create = try #require(harness.requests.first?.jsonBody as? [String: Any])
        #expect(create["libraryId"] as? String == "lib")
        #expect((create["items"] as? [[String: String]]) == [["libraryItemId": "li_pod", "episodeId": "ep"]])
        #expect(harness.requests.last?.path == "/api/playlists/pl_new/batch/remove")
    }
}

@Suite struct AuthenticatorTests {
    @Test func statusRejectsUninitializedServers() async throws {
        let host = MockURLProtocol.register { _ in .json(#"{"isInit":false,"authMethods":[]}"#) }
        await #expect(throws: APIError.serverNotInitialized) {
            try await ServerAuthenticator.status(host: host, headers: [])
        }
    }

    @Test func statusReadsMethods() async throws {
        let host = MockURLProtocol.register(path: "/abs") { _ in .fixture("status") }
        let status = try await ServerAuthenticator.status(host: host, headers: [HTTPHeader(key: "X-Proxy", value: "1")])
        #expect(status.authMethods == [.local, .openID])
        #expect(status.isOutdated)
        let request = try #require(MockURLProtocol.requests(for: host).first)
        #expect(request.path == "/abs/status")
        #expect(request.header("X-Proxy") == "1")
        #expect(request.header("Authorization") == nil)
    }

    @Test func loginRequestsTokens() async throws {
        let host = MockURLProtocol.register { _ in .fixture("login") }
        let result = try await ServerAuthenticator.login(host: host, headers: [], username: "robin", password: "pw")
        #expect(result.tokens.refreshToken == "refresh-1")
        #expect(result.tokens.accessToken == "access-1")

        let request = try #require(MockURLProtocol.requests(for: host).first)
        #expect(request.method == "POST")
        #expect(request.header("x-return-tokens") == "true")
        #expect((request.jsonBody as? [String: String]) == ["username": "robin", "password": "pw"])
    }

    @Test func loginFallsBackToLegacyToken() async throws {
        let host = MockURLProtocol.register { _ in .json(#"{"user":{"id":"u","username":"robin","token":"old"}}"#) }
        let result = try await ServerAuthenticator.login(host: host, headers: [], username: "robin", password: "pw")
        #expect(result.tokens == AuthTokens(accessToken: "old", refreshToken: nil))
        #expect(result.tokens.isLegacy)
    }

    @Test func wrongPasswordIsUnauthorized() async throws {
        let host = MockURLProtocol.register { _ in .status(401) }
        await #expect(throws: APIError.unauthorized) {
            try await ServerAuthenticator.login(host: host, headers: [], username: "robin", password: "bad")
        }
        #expect(MockURLProtocol.requests(for: host).count == 1)
    }

    @Test func openIDFlow() async throws {
        let host = MockURLProtocol.register(path: "/abs") { request in
            if request.path == "/abs/auth/openid" {
                return MockResponse(status: 302, headers: ["Location": "https://idp.example.com/authorize?client_id=abs&state=s1", "Set-Cookie": "connect.sid=abc; Path=/"])
            }
            return .fixture("login")
        }

        let authorization = try await ServerAuthenticator.beginOpenID(host: host, headers: [])
        #expect(authorization.authorizationURL.absoluteString == "https://idp.example.com/authorize?client_id=abs&state=s1")
        #expect(authorization.codeVerifier.count >= 64)

        let begin = try #require(MockURLProtocol.requests(for: host).first)
        #expect(begin.query("client_id") == "Hearth")
        #expect(begin.query("redirect_uri") == "hearth://oauth")
        #expect(begin.query("code_challenge_method") == "S256")
        #expect(begin.query("response_type") == "code")
        #expect(begin.query("code_challenge") == PKCE.challenge(for: authorization.codeVerifier))

        let callback = URL(string: "hearth://oauth?code=the-code&state=s1")!
        let result = try await ServerAuthenticator.completeOpenID(host: host, headers: [], callbackURL: callback, codeVerifier: authorization.codeVerifier)
        #expect(result.tokens.accessToken == "access-1")

        let complete = try #require(MockURLProtocol.requests(for: host).last)
        #expect(complete.path == "/abs/auth/openid/callback")
        #expect(complete.query("code") == "the-code")
        #expect(complete.query("state") == "s1")
        #expect(complete.query("code_verifier") == authorization.codeVerifier)
    }

    @Test func openIDCallbackWithoutCodeFails() async {
        let host = MockURLProtocol.register { _ in .fixture("login") }
        await #expect(throws: APIError.invalidURL) {
            try await ServerAuthenticator.completeOpenID(host: host, headers: [], callbackURL: URL(string: "hearth://oauth?state=x")!, codeVerifier: "v")
        }
        await #expect(throws: APIError.unauthorized) {
            try await ServerAuthenticator.completeOpenID(host: host, headers: [], callbackURL: URL(string: "hearth://oauth?error=access_denied")!, codeVerifier: "v")
        }
    }
}

@Suite struct ServerEventMappingTests {
    func makeMapper() -> (ServerEventMapper, PayloadConverter) {
        let host = MockURLProtocol.register { request in
            request.path == "/api/items/batch/get" ? .fixture("batch-get") : .status(404)
        }
        let connection = Connection(host: host, username: "robin")
        let executor = RequestExecutor(connection: connection, tokenStore: MockTokenStore(AuthTokens(accessToken: "a", refreshToken: nil), for: connection.id), delegate: nil)
        let converter = PayloadConverter(connectionID: connection.id, host: host)
        let mapper = ServerEventMapper(converter: converter, resolver: LibraryResolver(executor: executor, directory: converter.directory), executor: executor, broadcaster: EventBroadcaster())
        return (mapper, converter)
    }

    @Test func mapsProgressUpdates() async throws {
        let (mapper, converter) = makeMapper()
        let payload = Data(#"{"id":"mp_ep1","sessionId":"s","deviceDescription":"iPhone","data":{"id":"mp_ep1","libraryItemId":"li_pod1","episodeId":"ep_1","progress":0.5,"currentTime":60,"duration":120,"isFinished":false,"lastUpdate":1700000000000}}"#.utf8)
        let events = await mapper.map(name: "user_item_progress_updated", payload: payload)
        guard case .progressUpdated(let progress) = events.first else {
            Issue.record("Expected progress event")
            return
        }
        #expect(progress.itemID == converter.identifier(.episode, library: "lib_pods", primary: "ep_1", grouping: "li_pod1"))
        #expect(progress.currentTime == 60)
    }

    @Test func mapsItemEvents() async throws {
        let (mapper, converter) = makeMapper()
        let item = try Fixture.data("item-podcast-expanded")
        let updated = await mapper.map(name: "item_updated", payload: item)
        guard case .itemUpdated(let id) = updated.first else {
            Issue.record("Expected item event")
            return
        }
        #expect(id.kind == .podcast)
        #expect(id == converter.identifier(.podcast, library: "lib_pods", primary: "li_pod1"))

        let added = await mapper.map(name: "items_added", payload: Data("[\(String(decoding: item, as: UTF8.self))]".utf8))
        guard case .itemAdded(let library) = added.first else {
            Issue.record("Expected item added")
            return
        }
        #expect(library.libraryID == "lib_pods")

        let removed = await mapper.map(name: "item_removed", payload: Data(#"{"id":"li_pod1","libraryId":"lib_pods"}"#.utf8))
        guard case .itemRemoved(let removedID) = removed.first else {
            Issue.record("Expected item removed")
            return
        }
        #expect(removedID.kind == .podcast)
        #expect(removedID.primaryID == "li_pod1")

        let user = await mapper.map(name: "user_updated", payload: Data("{}".utf8))
        guard case .userUpdated = user.first else {
            Issue.record("Expected user updated")
            return
        }
        #expect(await mapper.map(name: "unknown_event", payload: nil).isEmpty)
    }

    @Test func broadcasterFansOut() async {
        let broadcaster = EventBroadcaster<Int>()
        let first = broadcaster.stream()
        let second = broadcaster.stream()
        broadcaster.yield(1)
        broadcaster.yield(2)
        broadcaster.finish()
        var a: [Int] = []
        for await value in first { a.append(value) }
        var b: [Int] = []
        for await value in second { b.append(value) }
        #expect(a == [1, 2])
        #expect(b == [1, 2])
        #expect(broadcaster.subscriberCount == 0)
    }
}
}
