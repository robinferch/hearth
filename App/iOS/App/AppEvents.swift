import Foundation
import HearthModel
import Observation

/// Requests that originate outside a scene (quick actions, URLs from other apps, intents) and are
/// consumed by the first scene that sees them.
enum ExternalRequest: Hashable, Sendable {
    case open(ItemIdentifier)
    case play(ItemIdentifier)
    case search(String?)
    /// Listen Now sheet (Listen Now / Play widgets).
    case listenNow
    /// Listening statistics (Listened Today widget).
    case statistics
    /// Full-screen player (Now Playing complication / Live Activity).
    case nowPlaying
}

@MainActor
@Observable
final class AppEvents {
    static let shared = AppEvents()

    /// Latest unhandled request.
    var pending: ExternalRequest?

    /// True after `HearthData.bootstrap()` returned (the stores may still be loading in the background).
    var bootstrapFinished = false

    private init() {}

    func post(_ request: ExternalRequest) {
        pending = request
    }

    /// Returns and clears the pending request.
    func consume() -> ExternalRequest? {
        defer { pending = nil }
        return pending
    }
}

/// Parses `hearth://` URLs.
enum DeepLink {
    /// `hearth://item/<id>`, `hearth://play/<id>`, `hearth://search?q=…`, `hearth://listen-now`,
    /// `hearth://statistics`, `hearth://nowplaying`. `hearth://oauth` is handled by the authentication session
    /// and ignored here.
    static func request(for url: URL) -> ExternalRequest? {
        guard url.scheme?.lowercased() == "hearth", let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let host = components.host?.lowercased()
        let argument = components.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .removingPercentEncoding ?? ""
        switch host {
        case "item":
            return ItemIdentifier(argument).map { .open($0) }
        case "play":
            return ItemIdentifier(argument).map { .play($0) }
        case "search":
            let query = components.queryItems?.first { $0.name == "q" }?.value
            return .search(query)
        case "listen-now":
            return .listenNow
        case "statistics":
            return .statistics
        case "nowplaying", "now-playing":
            return .nowPlaying
        default:
            return nil
        }
    }

    static func url(for request: ExternalRequest) -> URL? {
        var components = URLComponents()
        components.scheme = "hearth"
        switch request {
        case .open(let id):
            components.host = "item"
            components.path = "/" + id.description
        case .play(let id):
            components.host = "play"
            components.path = "/" + id.description
        case .search(let query):
            components.host = "search"
            if let query {
                components.queryItems = [URLQueryItem(name: "q", value: query)]
            }
        case .listenNow:
            components.host = "listen-now"
        case .statistics:
            components.host = "statistics"
        case .nowPlaying:
            components.host = "nowplaying"
        }
        return components.url
    }
}

/// Handoff / Siri suggestion activity identifiers.
enum UserActivity {
    /// `<bundle id>.item`; `userInfo["itemID"]` / `targetContentIdentifier` = `ItemIdentifier.description`.
    static let itemType = (Bundle.main.bundleIdentifier ?? "dev.hearth.hearth") + ".item"
    static let itemIDKey = "itemID"

    static func itemID(from activity: NSUserActivity) -> ItemIdentifier? {
        if let string = activity.userInfo?[itemIDKey] as? String, let id = ItemIdentifier(string) {
            return id
        }
        return activity.targetContentIdentifier.flatMap(ItemIdentifier.init)
    }
}
