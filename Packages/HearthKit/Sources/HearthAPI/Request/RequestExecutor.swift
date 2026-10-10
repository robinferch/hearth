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
        request.applyHeaders(connectionHeaders: connection.headers, accessToken: await currentTokens()?.accessToken)
        return request.allHTTPHeaderFields ?? [:]
    }

    /// An authorized `URLRequest` for `request` without executing it (covers, downloads).
    func urlRequest(for request: APIRequest) async throws(APIError) -> URLRequest {
        try request.urlRequest(host: connection.host, connectionHeaders: connection.headers, accessToken: await currentTokens()?.accessToken)
    }

    func accessToken() async -> String? {
        await currentTokens()?.accessToken
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

    /// The access token to send, failing fast if the connection was already rejected.
    private func usableAccessToken() async throws(APIError) -> String? {
        let token = await currentTokens()?.accessToken
        if isRejected {
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
        return token
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

        guard let refreshToken = tokens?.refreshToken else {
            await markUnauthorized(staleAccessToken)
            throw .unauthorized
        }

        // The task applies the result itself so every waiter observes the new tokens on resumption.
        let task = Task<AuthTokens, any Error> {
            defer { self.refreshTask = nil }
            do throws(APIError) {
                let newTokens = try await self.requestTokenRefresh(refreshToken: refreshToken)
                self.tokens = newTokens
                await self.tokenStore.store(newTokens, for: self.connection.id)
                self.logger.info("Refreshed access token for \(self.connection.displayName, privacy: .private)")
                return newTokens
            } catch {
                switch error {
                case .unauthorized, .invalidResponse(statusCode: 400), .invalidResponse(statusCode: 403):
                    await self.markUnauthorized(staleAccessToken)
                    throw APIError.unauthorized
                default:
                    throw error
                }
            }
        }
        refreshTask = task
        return try await Self.value(of: task)
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
