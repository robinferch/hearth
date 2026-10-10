import Foundation
import HearthModel
import os

/// Unauthenticated calls used while adding a connection: status, password login and OpenID (PKCE).
enum AuthenticatorImplementation {
    private static let logger = Logger.api(AuthenticatorImplementation.self)

    static func status(host: URL, headers: [HTTPHeader], pinnedCertificateSHA256: String?) async throws -> ServerStatus {
        var request = APIRequest.get("status")
        request.authenticated = false
        let data = try await perform(request, host: host, headers: headers, pinned: pinnedCertificateSHA256)
        let payload = try decode(StatusPayload.self, from: data)

        guard payload.isInit else {
            throw APIError.serverNotInitialized
        }

        let status = ServerStatus(
            isInitialized: payload.isInit,
            authMethods: payload.authMethods.compactMap(AuthMethod.init(rawValue:)),
            serverVersion: payload.serverVersion,
            openIDButtonText: payload.openIDButtonText,
            openIDAutoLaunch: payload.openIDAutoLaunch
        )
        if status.isOutdated {
            logger.warning("Server version \(payload.serverVersion ?? "?", privacy: .public) is older than \(ServerStatus.minimumRecommendedVersion, privacy: .public) – no refresh tokens")
        }
        return status
    }

    static func login(host: URL, headers: [HTTPHeader], username: String, password: String, pinnedCertificateSHA256: String?) async throws -> LoginResult {
        var request = try APIRequest.post("login").json(LoginBody(username: username, password: password))
        request.authenticated = false
        request.retryable = false
        request.headers["x-return-tokens"] = "true"

        let data = try await perform(request, host: host, headers: headers, pinned: pinnedCertificateSHA256)
        return try loginResult(from: data)
    }

    static func beginOpenID(host: URL, headers: [HTTPHeader], pinnedCertificateSHA256: String?) async throws -> OpenIDAuthorization {
        let verifier = PKCE.makeVerifier()
        var request = APIRequest.get("auth", "openid", query: [
            URLQueryItem(name: "client_id", value: "Hearth"),
            URLQueryItem(name: "redirect_uri", value: ServerAuthenticator.callbackURL),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
        ])
        request.authenticated = false
        request.followsRedirects = false
        request.retryable = false

        // The server stores the OpenID session in a cookie; start from a clean slate.
        URLSessionFactory.clearCookies(for: host)

        let (_, response) = try await send(request, host: host, headers: headers, pinned: pinnedCertificateSHA256)
        guard (300 ..< 400).contains(response.statusCode),
              let location = response.value(forHTTPHeaderField: "Location"),
              let url = URL(string: location, relativeTo: host)?.absoluteURL else {
            logger.error("OpenID authorization did not redirect (status \(response.statusCode))")
            throw response.statusCode == 404 ? APIError.unsupportedAuthMethod : APIError.invalidResponse(statusCode: response.statusCode)
        }
        return OpenIDAuthorization(authorizationURL: url, codeVerifier: verifier)
    }

    static func completeOpenID(host: URL, headers: [HTTPHeader], callbackURL: URL, codeVerifier: String, pinnedCertificateSHA256: String?) async throws -> LoginResult {
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }

        if let error = value("error") {
            logger.error("OpenID provider returned error \(error, privacy: .public)")
            throw APIError.unauthorized
        }
        guard let code = value("code"), let state = value("state") else {
            throw APIError.invalidURL
        }

        var request = APIRequest.get("auth", "openid", "callback", query: [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_verifier", value: codeVerifier),
        ])
        request.authenticated = false
        request.retryable = false

        let data = try await perform(request, host: host, headers: headers, pinned: pinnedCertificateSHA256)
        return try loginResult(from: data)
    }

    // MARK: Helpers

    static func loginResult(from data: Data) throws -> LoginResult {
        let user = try decode(UserResponsePayload.self, from: data).user
        guard let accessToken = user.bestAccessToken else {
            throw APIError.decoding("Login response without token")
        }
        return LoginResult(
            tokens: AuthTokens(accessToken: accessToken, refreshToken: user.refreshToken),
            username: user.username,
            userID: user.id
        )
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder.api.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    private static func send(_ request: APIRequest, host: URL, headers: [HTTPHeader], pinned: String?) async throws(APIError) -> (Data, HTTPURLResponse) {
        if APINetworkPolicy.shared.isOffline, !request.allowsOffline {
            throw .offline
        }
        let session = URLSessionFactory.makeSession(timeout: request.timeout)
        defer { session.finishTasksAndInvalidate() }
        let transport = HTTPTransport(session: session, pinnedSHA256: pinned, identityID: APIClientFactory.provisionalConnectionID(for: host))
        let urlRequest = try request.urlRequest(host: host, connectionHeaders: headers, accessToken: nil)
        return try await transport.send(urlRequest, followsRedirects: request.followsRedirects)
    }

    /// Sends with up to three attempts for retryable failures and validates the status code.
    private static func perform(_ request: APIRequest, host: URL, headers: [HTTPHeader], pinned: String?) async throws(APIError) -> Data {
        var attempt = 0
        while true {
            attempt += 1
            do throws(APIError) {
                let (data, response) = try await send(request, host: host, headers: headers, pinned: pinned)
                switch response.statusCode {
                case 200 ..< 300: return data
                case 401: throw .unauthorized
                case 404: throw .notFound
                default: throw .invalidResponse(statusCode: response.statusCode)
                }
            } catch {
                guard request.retryable, error.isRetryable, attempt < 3 else {
                    throw error
                }
                do {
                    try await Task.sleep(for: .milliseconds(300 * attempt))
                } catch {
                    throw .cancelled
                }
            }
        }
    }
}
