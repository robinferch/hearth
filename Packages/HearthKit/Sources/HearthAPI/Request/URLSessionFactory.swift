import Foundation
import Synchronization

/// Creates the URLSessions used by API clients and the authenticator.
enum URLSessionFactory {
    /// The app group shared with widgets/watch (cookie storage for OpenID). Mirrors `HearthData.AppGroup`.
    static let appGroupIdentifier: String = {
        if let value = Bundle.main.object(forInfoDictionaryKey: "HearthAppGroup") as? String, !value.isEmpty, !value.hasPrefix("$(") {
            return value
        }
        return "group.dev.hearth"
    }()

    static let cookieStorage: HTTPCookieStorage = HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: appGroupIdentifier)

    /// Test hook: protocol classes injected into every new session (e.g. a `URLProtocol` mock).
    private static let protocolOverride = Mutex<[AnyClass]?>(nil)

    static var protocolClassesOverride: [AnyClass]? {
        get { protocolOverride.withLock { $0 } }
        set { protocolOverride.withLock { $0 = newValue } }
    }

    static func makeConfiguration(timeout: TimeInterval = 45) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = cookieStorage
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 6
        if let protocolClasses = protocolClassesOverride {
            configuration.protocolClasses = protocolClasses + (configuration.protocolClasses ?? [])
        }
        return configuration
    }

    static func makeSession(timeout: TimeInterval = 45) -> URLSession {
        URLSession(configuration: makeConfiguration(timeout: timeout))
    }

    /// Removes all cookies stored for `host` (before starting an OpenID flow).
    static func clearCookies(for host: URL) {
        for cookie in cookieStorage.cookies(for: host) ?? [] {
            cookieStorage.deleteCookie(cookie)
        }
    }
}
