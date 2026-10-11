#if DEBUG
import Foundation
import HearthAPI
import HearthData
import HearthModel
import OSLog

/// Development helper: `-HearthDebugLogin <server url> <username> <password>` signs in on launch
/// (the simulator can't type comfortably and has no paired phone).
@MainActor
enum DebugLogin {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hearth", category: "DebugLogin")

    static func runIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-HearthDebugLogin"), arguments.count > index + 3 else { return }
        let input = arguments[index + 1]
        let username = arguments[index + 2]
        let password = arguments[index + 3]
        guard let host = Connection.normalizedHost(input) else {
            logger.error("Invalid debug login URL")
            return
        }
        let connections = HearthData.shared.connections
        if connections.connections.contains(where: { $0.host == host && $0.username == username }), connections.signedInConnections.contains(where: { $0.host == host }) {
            return
        }
        do {
            let status = try await ServerAuthenticator.status(host: host, headers: [])
            let result = try await ServerAuthenticator.login(host: host, headers: [], username: username, password: password)
            let connection = Connection(host: host, username: result.username, userID: result.userID, serverVersion: status.serverVersion)
            await connections.add(connection, tokens: result.tokens)
            logger.info("Debug login succeeded")
        } catch {
            logger.error("Debug login failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Screens & playback (simulator screenshots without touch input)

    private static func value(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.count > index + 1 else { return nil }
        return arguments[index + 1]
    }

    /// `-HearthDebugRoute nowPlaying,chapters` – comma-separated routes pushed at launch. Item routes resolve to the
    /// first entry of the first matching library: `book`, `series`, `seriesDetail`, `author`, `podcast`, `episode`.
    static func initialPath() async -> [WatchRoute]? {
        guard let value = value(after: "-HearthDebugRoute") else { return nil }
        var path: [WatchRoute] = []
        for token in value.split(separator: ",").map(String.init) {
            if let route = await route(for: token) {
                path.append(route)
            } else {
                logger.error("Unknown debug route \(token, privacy: .public)")
            }
        }
        return path
    }

    /// `-HearthDebugPlay book|episode` – starts the first audiobook / episode on the watch after bootstrap.
    /// `-HearthDebugDownload book|episode` – downloads it to the watch.
    static func runActions() async {
        if let kind = value(after: "-HearthDebugPlay"), let id = await firstPlayable(kind) {
            await WatchPlayer.shared.playLocally(id)
        }
        if let kind = value(after: "-HearthDebugDownload"), let id = await firstPlayable(kind) {
            do {
                try await HearthData.shared.downloads.download(id)
            } catch {
                logger.error("Debug download failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private static func route(for token: String) async -> WatchRoute? {
        switch token {
        case "nowPlaying": return .nowPlaying
        case "playerOptions": return .playerOptions
        case "chapters": return .chapters
        case "speed": return .playbackSpeed
        case "sleep": return .sleepTimer
        case "scrub": return .scrub
        case "listenNow": return .listenNow
        case "downloads": return .downloads
        case "settings": return .settings
        case "connections": return .connections
        case "library": return library(.audiobooks).map { .library($0) }
        case "audiobooks": return library(.audiobooks).map { .audiobooks($0) }
        case "series": return library(.audiobooks).map { .series($0) }
        case "authors": return library(.audiobooks).map { .authors($0) }
        case "podcasts": return library(.podcasts).map { .podcasts($0) }
        case "book", "episode": return await firstPlayable(token).map { .item($0) }
        case "seriesDetail":
            guard let library = library(.audiobooks), let client = try? WatchClient.for(library.connectionID),
                  let series = try? await client.series(library: library, sort: .name, direction: .ascending, filter: nil, page: 0, limit: 1).items.first else { return nil }
            return .item(series.id)
        case "author":
            guard let library = library(.audiobooks), let client = try? WatchClient.for(library.connectionID),
                  let author = try? await client.authors(library: library, sort: .firstLast, direction: .ascending, page: 0, limit: 1).items.first else { return nil }
            return .item(author.id)
        case "podcast":
            guard let library = library(.podcasts), let client = try? WatchClient.for(library.connectionID),
                  let podcast = try? await client.podcasts(library: library, sort: .title, direction: .ascending, page: 0, limit: 1).items.first else { return nil }
            return .item(podcast.id)
        default: return nil
        }
    }

    private static func library(_ type: Library.MediaType) -> LibraryIdentifier? {
        HearthData.shared.connections.allLibraries.first { $0.mediaType == type }?.id
    }

    private static func firstPlayable(_ kind: String) async -> ItemIdentifier? {
        if kind == "episode" {
            guard let library = library(.podcasts), let client = try? WatchClient.for(library.connectionID),
                  let podcast = try? await client.podcasts(library: library, sort: .title, direction: .ascending, page: 0, limit: 1).items.first,
                  let result = try? await HearthData.shared.items.podcast(podcast.id) else { return nil }
            return result.episodes.max { ($0.publishedAt ?? .distantPast) < ($1.publishedAt ?? .distantPast) }?.id
        }
        guard let library = library(.audiobooks), let client = try? WatchClient.for(library.connectionID),
              let page = try? await client.audiobooks(library: library, sort: .title, direction: .ascending, filter: nil, collapseSeries: false, page: 0, limit: 5) else { return nil }
        for entry in page.items {
            if case .audiobook(let audiobook) = entry {
                return audiobook.id
            }
        }
        return nil
    }
}
#endif
