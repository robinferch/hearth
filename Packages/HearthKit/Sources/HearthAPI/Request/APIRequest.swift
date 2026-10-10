import Foundation
import HearthModel

enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case patch = "PATCH"
    case delete = "DELETE"
}

/// Description of a single API call, independent of host and credentials.
struct APIRequest: Sendable {
    var method: HTTPMethod
    /// Path components appended to the host, each percent-encoded individually.
    var path: [String]
    var query: [URLQueryItem] = []
    var body: Data?
    /// Per-request headers, applied after the connection headers and the bearer token.
    var headers: [String: String] = [:]

    /// Attach `Authorization: Bearer …` and refresh on 401.
    var authenticated = true
    /// Skip the per-connection concurrency limiter (login, status, refresh, authorize).
    var bypassesLimiter = false
    /// Allowed even when `APINetworkPolicy.shared.isOffline` is set.
    var allowsOffline = false
    /// When set, successful GET responses are cached in memory for this long.
    var cacheTTL: Duration?
    /// `false` returns 3xx responses to the caller instead of following them.
    var followsRedirects = true
    /// Whether failed attempts may be retried.
    var retryable = true
    var timeout: TimeInterval = 45

    init(method: HTTPMethod, path: [String], query: [URLQueryItem] = [], body: Data? = nil) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
    }

    static func get(_ path: String..., query: [URLQueryItem] = []) -> APIRequest {
        APIRequest(method: .get, path: path, query: query)
    }

    static func post(_ path: String..., query: [URLQueryItem] = []) -> APIRequest {
        APIRequest(method: .post, path: path, query: query)
    }

    static func patch(_ path: String..., query: [URLQueryItem] = []) -> APIRequest {
        APIRequest(method: .patch, path: path, query: query)
    }

    static func delete(_ path: String..., query: [URLQueryItem] = []) -> APIRequest {
        APIRequest(method: .delete, path: path, query: query)
    }

    /// Encodes `value` as the JSON body.
    func json(_ value: some Encodable) throws(APIError) -> APIRequest {
        var copy = self
        do {
            copy.body = try JSONEncoder.api.encode(value)
        } catch {
            throw .decoding("Encoding request body failed: \(error)")
        }
        return copy
    }

    /// Caches the response of list endpoints for a short time.
    func cached(_ ttl: Duration = .seconds(12)) -> APIRequest {
        var copy = self
        copy.cacheTTL = ttl
        return copy
    }

    var hasJSONBody: Bool { body != nil }

    /// Builds the final `URLRequest`. Header order: connection headers (sorted by key) → bearer → per-request headers.
    func urlRequest(host: URL, connectionHeaders: [HTTPHeader], accessToken: String?) throws(APIError) -> URLRequest {
        let url = try URLBuilder.url(host: host, path: path, query: query)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method.rawValue
        request.applyHeaders(connectionHeaders: connectionHeaders, accessToken: authenticated ? accessToken : nil)
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    /// Identity used for de-duplicating and caching GET requests.
    func cacheKey(host: URL) -> String? {
        guard method == .get, let url = try? URLBuilder.url(host: host, path: path, query: query) else {
            return nil
        }
        return url.absoluteString
    }
}

extension URLRequest {
    /// Applies connection headers sorted by key, followed by the bearer token.
    mutating func applyHeaders(connectionHeaders: [HTTPHeader], accessToken: String?) {
        for header in connectionHeaders.sorted(by: { $0.key < $1.key }) where !header.key.isEmpty {
            setValue(header.value, forHTTPHeaderField: header.key)
        }
        if let accessToken, !accessToken.isEmpty {
            setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
    }
}

extension JSONEncoder {
    static var api: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
