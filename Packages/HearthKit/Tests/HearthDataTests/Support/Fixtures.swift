import Foundation
@testable import HearthData
import HearthAPI
import HearthModel

enum Fixtures {
    static let host = URL(string: "https://abs.example.com")!

    static func connection(_ username: String = "alice") -> Connection {
        Connection(host: host, username: username, addedAt: Date(timeIntervalSince1970: 0))
    }

    static func bookID(_ id: String, connection: ConnectionID, library: String = "books") -> ItemIdentifier {
        ItemIdentifier(kind: .audiobook, connectionID: connection, libraryID: library, primaryID: id)
    }

    static func episodeID(_ id: String, podcast: String, connection: ConnectionID, library: String = "pods") -> ItemIdentifier {
        ItemIdentifier(kind: .episode, connectionID: connection, libraryID: library, primaryID: id, groupingID: podcast)
    }

    static func book(_ id: String, connection: ConnectionID, library: String = "books", name: String? = nil, authors: [String] = [], series: [SeriesFragment] = [], duration: TimeInterval = 3600, addedAt: Date? = nil) -> Audiobook {
        Audiobook(id: bookID(id, connection: connection, library: library), name: name ?? "Book \(id)", authors: authors, series: series, addedAt: addedAt, duration: duration)
    }

    static func episode(_ id: String, podcast: String = "pod", connection: ConnectionID, name: String? = nil, season: String? = nil, number: String? = nil, published: Date? = nil, duration: TimeInterval = 1800) -> Episode {
        Episode(id: episodeID(id, podcast: podcast, connection: connection), name: name ?? "Episode \(id)", podcastName: "Podcast", publishedAt: published, season: season, episode: number, duration: duration)
    }

    static func progress(_ itemID: ItemIdentifier, id: String? = nil, currentTime: TimeInterval, duration: TimeInterval = 100, lastUpdate: Date, hidden: Bool = false) -> ProgressEntity {
        ProgressEntity(id: id ?? "p-\(itemID.primaryID)", itemID: itemID, progress: min(1, currentTime / duration), duration: duration, currentTime: currentTime, startedAt: lastUpdate, lastUpdate: lastUpdate, finishedAt: currentTime >= duration ? lastUpdate : nil, hideFromContinueListening: hidden)
    }

    static func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + seconds)
    }
}

/// Builds an isolated `HearthData` graph backed by mock clients.
@MainActor
func makeHearth(_ clients: [MockClient]) -> HearthData {
    let environment = DataEnvironment.ephemeral(
        connections: clients.map(\.connection),
        tokens: Dictionary(clients.map { ($0.connection.id, AuthTokens(accessToken: "token", refreshToken: "refresh")) }, uniquingKeysWith: { $1 }),
        clientFactory: { connection, _, _ in
            clients.first { $0.connection.id == connection.id } ?? MockClient(connection: connection)
        }
    )
    return HearthData(environment: environment, settings: AppSettings(defaults: environment.defaults))
}
