import Foundation

/// Response of `POST api/items/{id}/play[/{episodeId}]` and entries of listening session lists.
struct PlaybackSessionPayload: Decodable, Sendable {
    var id: String
    var libraryID: String?
    var libraryItemID: String?
    var episodeID: String?
    var mediaType: String?
    var displayTitle: String?
    var displayAuthor: String?
    var duration: Double
    var startTime: Double?
    var currentTime: Double?
    var timeListening: Double
    var startedAt: Date?
    var updatedAt: Date?
    var date: String?
    var chapters: [ChapterPayload]
    var audioTracks: [AudioTrackPayload]
    var deviceInfo: DeviceInfoPayload?
    var libraryItem: LibraryItemPayload?
    var mediaMetadataTitle: String?

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        guard let id = c.nonEmptyString("id") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Session without id"))
        }
        self.id = id
        libraryID = c.nonEmptyString("libraryId")
        libraryItemID = c.nonEmptyString("libraryItemId")
        episodeID = c.nonEmptyString("episodeId")
        mediaType = c.nonEmptyString("mediaType")
        displayTitle = c.nonEmptyString("displayTitle")
        displayAuthor = c.nonEmptyString("displayAuthor")
        duration = c.double("duration") ?? 0
        startTime = c.double("startTime")
        currentTime = c.double("currentTime")
        timeListening = c.double("timeListening") ?? 0
        startedAt = c.dateMS("startedAt")
        updatedAt = c.dateMS("updatedAt")
        date = c.nonEmptyString("date")
        chapters = c.array("chapters")
        audioTracks = c.array("audioTracks")
        deviceInfo = c.decode("deviceInfo")
        libraryItem = c.decode("libraryItem")
        mediaMetadataTitle = c.decode("mediaMetadata", as: TitledPayload.self)?.title
    }
}

struct DeviceInfoPayload: Decodable, Sendable {
    var deviceName: String?
    var model: String?
    var clientName: String?
    var osName: String?
    var browserName: String?

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        deviceName = c.nonEmptyString("deviceName")
        model = c.nonEmptyString("model")
        clientName = c.nonEmptyString("clientName")
        osName = c.nonEmptyString("osName")
        browserName = c.nonEmptyString("browserName")
    }

    /// Best human readable description of the device.
    var displayName: String? {
        if let deviceName {
            return deviceName
        }
        let parts = [clientName ?? browserName, model ?? osName].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " – ")
    }
}

struct TitledPayload: Decodable, Sendable {
    var title: String?

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        title = c.nonEmptyString("title")
    }
}

/// `GET api/me/listening-sessions` and `api/me/item/listening-sessions/…`.
struct ListeningSessionsPayload: Decodable, Sendable {
    var total: Int?
    var page: Int?
    var sessions: [PlaybackSessionPayload]

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        total = c.int("total")
        page = c.int("page")
        sessions = c.array("sessions")
    }
}

/// `GET api/me/listening-stats`.
struct ListeningStatsPayload: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        var id: String
        var timeListening: Double
        var title: String?

        init(from decoder: any Decoder) throws {
            let c = try decoder.lenient()
            id = c.string("id") ?? ""
            timeListening = c.double("timeListening") ?? 0
            title = c.decode("mediaMetadata", as: TitledPayload.self)?.title
        }
    }

    var totalTime: Double
    var today: Double
    var days: [String: Double]
    var items: [String: Item]

    init(from decoder: any Decoder) throws {
        let c = try decoder.lenient()
        totalTime = c.double("totalTime") ?? 0
        today = c.double("today") ?? 0

        var days: [String: Double] = [:]
        if let container = try? c.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("days")) {
            for key in container.allKeys {
                days[key.stringValue] = container.double(key.stringValue)
            }
        }
        self.days = days

        var items: [String: Item] = [:]
        if let container = try? c.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("items")) {
            for key in container.allKeys {
                guard var item = container.decode(key.stringValue, as: Item.self) else { continue }
                if item.id.isEmpty {
                    item.id = key.stringValue
                }
                items[key.stringValue] = item
            }
        }
        self.items = items
    }
}
