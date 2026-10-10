import Foundation

/// Builds request URLs relative to a connection's host.
///
/// Hosts may contain a sub-path (`https://example.com/abs`). Path components are appended to that
/// sub-path one by one and each component is percent-encoded on its own, so ids containing `/`, `+`
/// or `=` (e.g. base64 values) can never change the path structure.
enum URLBuilder {
    /// Characters that never need escaping (RFC 3986 "unreserved").
    static let unreserved: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return set
    }()

    /// Percent-encodes everything except unreserved characters.
    static func encode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }

    static func url(host: URL, path: [String], query: [URLQueryItem] = []) throws(APIError) -> URL {
        guard var components = URLComponents(url: host, resolvingAgainstBaseURL: false), components.host?.isEmpty == false else {
            throw .invalidURL
        }

        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") {
            basePath.removeLast()
        }

        let appended = path.map(encode).joined(separator: "/")
        components.percentEncodedPath = appended.isEmpty ? basePath : basePath + "/" + appended
        components.fragment = nil

        if query.isEmpty {
            components.percentEncodedQuery = nil
        } else {
            components.percentEncodedQuery = query
                .map { item in
                    if let value = item.value {
                        "\(encode(item.name))=\(encode(value))"
                    } else {
                        encode(item.name)
                    }
                }
                .joined(separator: "&")
        }

        guard let url = components.url else {
            throw .invalidURL
        }
        return url
    }

    /// Resolves a server supplied path such as `/api/items/x/file/y` (a track `contentUrl`) against the host.
    ///
    /// Absolute URLs are returned unchanged. If the path already contains the host's sub-path it is not
    /// prefixed a second time.
    static func resolve(serverPath: String, host: URL) -> URL? {
        if let absolute = URL(string: serverPath), absolute.scheme != nil {
            return absolute
        }
        guard var components = URLComponents(url: host, resolvingAgainstBaseURL: false) else {
            return nil
        }

        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") {
            basePath.removeLast()
        }

        let pathAndQuery = serverPath.hasPrefix("/") ? serverPath : "/" + serverPath
        let (path, query): (String, String?) = {
            guard let index = pathAndQuery.firstIndex(of: "?") else { return (pathAndQuery, nil) }
            return (String(pathAndQuery[..<index]), String(pathAndQuery[pathAndQuery.index(after: index)...]))
        }()

        if !basePath.isEmpty, path == basePath || path.hasPrefix(basePath + "/") {
            components.percentEncodedPath = path
        } else {
            components.percentEncodedPath = basePath + path
        }
        components.percentEncodedQuery = query
        components.fragment = nil
        return components.url
    }

    /// The WebSocket URL for Socket.IO (`…/socket.io/?EIO=4&transport=websocket`).
    static func socketURL(host: URL) throws(APIError) -> URL {
        let http = try url(host: host, path: ["socket.io", ""], query: [
            URLQueryItem(name: "EIO", value: "4"),
            URLQueryItem(name: "transport", value: "websocket"),
        ])
        guard var components = URLComponents(url: http, resolvingAgainstBaseURL: false) else {
            throw .invalidURL
        }
        components.scheme = components.scheme?.lowercased() == "http" ? "ws" : "wss"
        guard let url = components.url else {
            throw .invalidURL
        }
        return url
    }
}
