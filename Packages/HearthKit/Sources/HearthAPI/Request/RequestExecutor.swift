import Foundation
import HearthModel
import os

/// Executes API requests for one connection.
///
/// Responsibilities: offline gate, bearer token, concurrency limit, de-duplication of identical in-flight
/// GETs, a short-lived memory cache, retries and single-flight token refresh on 401.
actor RequestExecutor {
    struct Configuration: Sendable {
        var maxAttempts = 3
        var concurrencyLimit = 6
        /// Base delay between attempts; attempt `n` waits `n × retryDelay`.
        var retryDelay: Duration = .milliseconds(500)
        /// Access tokens expiring sooner are refreshed before a request is sent.
        var requestTokenValidity: TimeInterval = 60
        /// Minimum remaining lifetime of tokens handed out for requests executed elsewhere (downloads, covers,
        /// streaming headers), which may run a while after they were built.
        var handoffTokenValidity: TimeInterval = 15 * 60
    }

    let connection: Connection
    private let transport: HTTPTransport
    private let tokenStore: any TokenStore
    private weak var delegate: (any APIClientDelegate)?
    private let configuration: Configuration
    private let limiter: AsyncSemaphore
    private let logger = Logger.api(RequestExecutor.self)

    private var tokens: AuthTokens?
    private var refreshTask: Task<AuthTokens, any Error>?
    /// Set when the refresh token was rejected. Cleared when the token store provides different tokens.
    private var isRejected = false
    private var rejectedAccessToken: String?
    private var inFlight: [String: Task<Data, any Error>] = [:]
    private var cache: [String: (expires: ContinuousClock.Instant, data: Data)] = [:]

    init(connection: Connection, tokenStore: any TokenStore, delegate: (any APIClientDelegate)?, configuration: Configuration = Configuration()) {
        self.connection = connection
        self.tokenStore = tokenStore
        self.delegate = delegate
        self.configuration = configuration
        self.limiter = AsyncSemaphore(limit: configuration.concurrencyLimit)
        self.transport = HTTPTransport(session: URLSessionFactory.makeSession(), pinnedSHA256: connection.pinnedCertificateSHA256, identityID: connection.id)
    }

    nonisolated var session: URLSession { transport.session }

    // MARK: Public entry points

    /// Performs `request` and returns the response body of a 2xx response.
    func data(for request: APIRequest) async throws(APIError) -> Data {
        if APINetworkPolicy.shared.isOffline, !request.allowsOffline {
            throw .offline
        }

        guard let key = request.cacheKey(host: connection.host) else {
            // Mutations invalidate cached lists so the next read reflects the change.
            let data = try await perform(request)
            cache.removeAll()
            return data
        }

        if request.cacheTTL != nil, let entry = cache[key] {
            if entry.expires > .now {
                return entry.data
            }
            cache[key] = nil
        }

        if let existing = inFlight[key] {
            return try await Self.value(of: existing)
        }

        let task = Task<Data, any Error> {
            try await self.perform(request)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }

        let data = try await Self.value(of: task)
        if let ttl = request.cacheTTL {
            cache[key] = (ContinuousClock.now.advanced(by: ttl), data)
        }
        return data
    }

    /// Current headers for authorized downloads / streaming: custom headers + bearer.
    func authorizationHeaders() async -> [String: String] {
        var request = URLRequest(url: connection.host)
        request.applyHeaders(connectionHeaders: connection.headers, accessToken: await accessToken(validFor: configuration.handoffTokenValidity))
        return request.allHTTPHeaderFields ?? [:]
    }

    /// An authorized `URLRequest` for `request` without executing it (covers, downloads).
    func urlRequest(for request: APIRequest) async throws(APIError) -> URLRequest {
        try request.urlRequest(host: connection.host, connectionHeaders: connection.headers, accessToken: await accessToken(validFor: configuration.handoffTokenValidity))
    }

    func accessToken() async -> String? {
        await accessToken(validFor: configuration.requestTokenValidity)
    }

    /// Drops all cached responses.
    func invalidateCache() {
        cache.removeAll()
    }

    /// Forces a token refresh, e.g. after the socket reported `auth_failed`.
    func refreshAfterRejection(of accessToken: String?) async throws(APIError) {
        _ = try await refreshedTokens(replacing: accessToken)
    }

    // MARK: Execution

    private static func value(of task: Task<Data, any Error>) async throws(APIError) -> Data {
        do {
            return try await task.value
        } catch {
            throw HTTPTransport.map(error)
        }
    }

    private func perform(_ request: APIRequest) async throws(APIError) -> Data {
        var attempt = 0
        /// Set after a successful refresh so the retry uses exactly the refreshed token.
        var refreshedToken: String?

        while true {
            attempt += 1
            if Task.isCancelled {
                throw .cancelled
            }

            let token: String?
            if !request.authenticated {
                token = nil
            } else if let refreshedToken {
                token = refreshedToken
            } else {
                token = try await usableAccessToken()
            }

            do {
                return try await send(request, accessToken: token)
            } catch .unauthorized where request.authenticated && refreshedToken == nil {
                attempt -= 1
                refreshedToken = try await refreshedTokens(replacing: token).accessToken
            } catch {
                guard error.isRetryable, request.retryable, attempt < configuration.maxAttempts else {
                    throw error
                }
                logger.info("Retrying \(request.method.rawValue) \(request.path.joined(separator: "/"), privacy: .public) after \(String(describing: error), privacy: .public) (attempt \(attempt))")
                do {
                    try await Task.sleep(for: configuration.retryDelay * attempt)
                } catch {
                    throw .cancelled
                }
            }
        }
    }

    private func send(_ request: APIRequest, accessToken: String?) async throws(APIError) -> Data {
        let urlRequest = try request.urlRequest(host: connection.host, connectionHeaders: connection.headers, accessToken: accessToken)

        if !request.bypassesLimiter {
            await limiter.acquire()
        }
        let result: Result<(Data, HTTPURLResponse), APIError>
        do throws(APIError) {
            result = .success(try await transport.send(urlRequest, followsRedirects: request.followsRedirects))
        } catch {
            result = .failure(error)
        }
        if !request.bypassesLimiter {
            await limiter.release()
        }

        let (data, response) = try result.get()
        switch response.statusCode {
        case 200 ..< 300:
            return data
        case 401:
            throw .unauthorized
        case 404:
            throw .notFound
        case 300 ..< 400 where !request.followsRedirects:
            return data
        default:
            logger.error("\(request.method.rawValue) \(request.path.joined(separator: "/"), privacy: .public) failed with status \(response.statusCode)")
            throw .invalidResponse(statusCode: response.statusCode)
        }
    }

    // MARK: Tokens

    private func currentTokens() async -> AuthTokens? {
        if let tokens {
            return tokens
        }
        tokens = await tokenStore.tokens(for: connection.id)
        return tokens
    }

    /// The current access token, refreshed first when it expires within `interval` (JWT `exp`). Falls back to the
    /// current token if refreshing fails for other reasons than a rejected refresh token; the request then takes the
    /// regular 401 path.
    private func accessToken(validFor interval: TimeInterval) async -> String? {
        guard let current = await currentTokens() else { return nil }
        guard !isRejected, current.refreshToken != nil, let expiry = JWT.expiry(of: current.accessToken), expiry.timeIntervalSinceNow < interval else {
            return current.accessToken
        }
        do {
            return try await refreshedTokens(replacing: current.accessToken).accessToken
        } catch {
            return tokens?.accessToken ?? current.accessToken
        }
    }

    /// The access token to send, failing fast if the connection was already rejected.
    private func usableAccessToken() async throws(APIError) -> String? {
        guard isRejected else {
            return await accessToken(validFor: configuration.requestTokenValidity)
        }
        // Pick up tokens stored after a re-login.
        let stored = await tokenStore.tokens(for: connection.id)
        if let stored, stored.accessToken != rejectedAccessToken {
            tokens = stored
            isRejected = false
            rejectedAccessToken = nil
            return stored.accessToken
        }
        throw .unauthorized
    }

    /// Returns tokens newer than `staleAccessToken`, refreshing at most once concurrently.
    private func refreshedTokens(replacing staleAccessToken: String?) async throws(APIError) -> AuthTokens {
        if let tokens, tokens.accessToken != staleAccessToken {
            return tokens
        }
        if let stored = await tokenStore.tokens(for: connection.id), stored.accessToken != staleAccessToken {
            tokens = stored
            return stored
        }
        if isRejected {
            throw .unauthorized
        }

        if let refreshTask {
            return try await Self.value(of: refreshTask)
        }

        guard let current = tokens, current.refreshToken != nil else {
            await markUnauthorized(staleAccessToken)
            throw .unauthorized
        }

        // The task applies the result itself so every waiter observes the new tokens on resumption.
        let task = Task<AuthTokens, any Error> {
            defer { self.refreshTask = nil }
            return try await self.performRefresh(from: current, staleAccessToken: staleAccessToken)
        }
        refreshTask = task
        return try await Self.value(of: task)
    }

    /// Rotates `current`'s refresh token. Runs as the single in-flight refresh task.
    ///
    /// The server invalidates the old refresh token as soon as it handles the request (after a grace period of a few
    /// minutes on recent servers), so the response must not get lost: the process is kept running until the new tokens
    /// are stored. Another holder of the same session (the paired iPhone or watch) is consulted before rotating and
    /// before giving up, because it may have rotated the token already.
    private func performRefresh(from current: AuthTokens, staleAccessToken: String?) async throws(APIError) -> AuthTokens {
        let activity = ExpiringActivity(reason: "Refreshing the audiobookshelf session")
        defer { activity.end() }

        var current = current
        if let external = await externalTokens(current: current, reason: .aboutToRefresh) {
            if let expiry = JWT.expiry(of: external.accessToken), expiry.timeIntervalSinceNow < configuration.requestTokenValidity {
                // Still has to be refreshed, but with the refresh token that is valid now.
                current = external
            } else {
                return external
            }
        }

        var triedRefreshTokens = Set<String>()
        while let refreshToken = current.refreshToken, triedRefreshTokens.insert(refreshToken).inserted {
            do throws(APIError) {
                let newTokens = try await requestTokenRefresh(refreshToken: refreshToken)
                tokens = newTokens
                await tokenStore.store(newTokens, for: connection.id)
                logger.info("Refreshed access token for \(self.connection.displayName, privacy: .private)")
                return newTokens
            } catch .unauthorized {
                // audiobookshelf answers every rejected refresh with 401. Other statuses (403 from a proxy, 5xx while
                // the server restarts) and network errors are transient: the session may still be valid.
                logger.error("The server rejected the refresh token of \(self.connection.displayName, privacy: .private)")
                guard let external = await externalTokens(current: current, reason: .refreshRejected) else { break }
                if let expiry = JWT.expiry(of: external.accessToken), expiry.timeIntervalSinceNow >= configuration.requestTokenValidity {
                    logger.info("Recovered the session of \(self.connection.displayName, privacy: .private) from the paired device")
                    return external
                }
                current = external
            }
        }
        await markUnauthorized(staleAccessToken)
        throw .unauthorized
    }

    /// Tokens from another holder of the session that differ from `current`, adopted as the executor's tokens.
    private func externalTokens(current: AuthTokens, reason: ExternalTokenReason) async -> AuthTokens? {
        guard let external = await tokenStore.externalTokens(for: connection.id, current: current, reason: reason), external != current else {
            return nil
        }
        tokens = external
        return external
    }

    private static func value(of task: Task<AuthTokens, any Error>) async throws(APIError) -> AuthTokens {
        do {
            return try await task.value
        } catch {
            throw HTTPTransport.map(error)
        }
    }

    private func requestTokenRefresh(refreshToken: String) async throws(APIError) -> AuthTokens {
        var request = APIRequest.post("auth", "refresh")
        request.authenticated = false
        request.bypassesLimiter = true
        request.retryable = false
        request.headers["x-refresh-token"] = refreshToken

        let data = try await send(request, accessToken: nil)
        let user: UserPayload
        do {
            user = try JSONDecoder.api.decode(UserResponsePayload.self, from: data).user
        } catch {
            throw .decoding(String(describing: error))
        }
        guard let accessToken = user.bestAccessToken else {
            throw .unauthorized
        }
        return AuthTokens(accessToken: accessToken, refreshToken: user.refreshToken ?? refreshToken)
    }

    private func markUnauthorized(_ accessToken: String?) async {
        guard !isRejected else { return }
        isRejected = true
        rejectedAccessToken = accessToken
        logger.error("Connection \(self.connection.displayName, privacy: .private) is no longer authorized")
        await delegate?.apiClientDidBecomeUnauthorized(connection.id)
    }
}
