import CryptoKit
import Foundation

public struct HTTPHeader: Hashable, Codable, Sendable, Identifiable {
    public var id = UUID()
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    enum CodingKeys: String, CodingKey {
        case key, value
    }
}

public enum AuthMethod: String, Codable, Sendable, CaseIterable {
    case local
    case openID = "openid"
}

/// A user account on an audiobookshelf server.
public struct Connection: Hashable, Codable, Sendable, Identifiable {
    public let id: ConnectionID
    public var host: URL
    public var username: String
    public var userID: String?
    public var headers: [HTTPHeader]
    public var addedAt: Date
    public var serverVersion: String?
    /// SHA-256 fingerprint (hex) of a self-signed leaf certificate the user chose to trust.
    public var pinnedCertificateSHA256: String?

    public init(host: URL, username: String, userID: String? = nil, headers: [HTTPHeader] = [], addedAt: Date = .now, serverVersion: String? = nil, pinnedCertificateSHA256: String? = nil) {
        self.id = Self.makeID(host: host, username: username)
        self.host = host
        self.username = username
        self.userID = userID
        self.headers = headers
        self.addedAt = addedAt
        self.serverVersion = serverVersion
        self.pinnedCertificateSHA256 = pinnedCertificateSHA256
    }

    public static func makeID(host: URL, username: String) -> ConnectionID {
        let digest = SHA256.hash(data: Data("host:\(host.absoluteString).user:\(username)".utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            .prefix(22)
            .description
    }

    public var displayName: String {
        "\(username)@\(host.host() ?? host.absoluteString)"
    }

    /// Normalises user input such as `abs.example.com/` into `https://abs.example.com`.
    public static func normalizedHost(_ input: String) -> URL? {
        var string = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while string.hasSuffix("/") {
            string.removeLast()
        }
        guard !string.isEmpty else { return nil }
        if !string.contains("://") {
            string = "https://" + string
        }
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host() != nil else {
            return nil
        }
        return url
    }
}

public struct ServerStatus: Hashable, Codable, Sendable {
    public var isInitialized: Bool
    public var authMethods: [AuthMethod]
    public var serverVersion: String?
    public var openIDButtonText: String?
    public var openIDAutoLaunch: Bool

    public init(isInitialized: Bool, authMethods: [AuthMethod], serverVersion: String?, openIDButtonText: String? = nil, openIDAutoLaunch: Bool = false) {
        self.isInitialized = isInitialized
        self.authMethods = authMethods
        self.serverVersion = serverVersion
        self.openIDButtonText = openIDButtonText
        self.openIDAutoLaunch = openIDAutoLaunch
    }

    public static let minimumRecommendedVersion = "2.26.0"

    public var isOutdated: Bool {
        guard let serverVersion else { return false }
        return serverVersion.compare(Self.minimumRecommendedVersion, options: .numeric) == .orderedAscending
    }
}

public struct AuthTokens: Hashable, Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String?

    public init(accessToken: String, refreshToken: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    public var isLegacy: Bool { refreshToken == nil }
}
