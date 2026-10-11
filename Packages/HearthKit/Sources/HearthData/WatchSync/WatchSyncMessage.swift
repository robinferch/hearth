import Foundation
import HearthModel

// Messages exchanged between the iPhone app and the watch app over WatchConnectivity.
// Every payload is JSON-encoded into a single `Data` value so the wire format stays versioned and
// independent of WatchConnectivity's property-list restrictions.

// MARK: - Credentials

/// Connections plus their tokens, sent from one device to the other.
public struct WatchCredentials: Codable, Sendable, Hashable {
    public struct Entry: Codable, Sendable, Hashable {
        public var connection: Connection
        public var tokens: AuthTokens
        /// When the sender last saw these tokens change. Receivers only replace newer tokens with newer ones.
        public var tokensChangedAt: Date
        /// PKCS#12 client certificate (mTLS) for the connection's host, if any.
        public var clientCertificate: Data?
        public var clientCertificatePassphrase: String?

        public init(connection: Connection, tokens: AuthTokens, tokensChangedAt: Date, clientCertificate: Data? = nil, clientCertificatePassphrase: String? = nil) {
            self.connection = connection
            self.tokens = tokens
            self.tokensChangedAt = tokensChangedAt
            self.clientCertificate = clientCertificate
            self.clientCertificatePassphrase = clientCertificatePassphrase
        }
    }

    public var entries: [Entry]
    public var sentAt: Date

    public init(entries: [Entry], sentAt: Date = .now) {
        self.entries = entries
        self.sentAt = sentAt
    }
}

// MARK: - Now playing

/// The player state of one device, as shown by the other (watch remote control, complications).
public struct WatchNowPlayingState: Codable, Sendable, Hashable {
    public var itemID: ItemIdentifier
    public var title: String
    /// Authors (books) or podcast name (episodes).
    public var subtitle: String?
    public var chapterTitle: String?
    public var chapterIndex: Int?
    /// Chapters of the item (capped to keep messages small).
    public var chapters: [Chapter]

    public var isPlaying: Bool
    public var isBuffering: Bool
    public var currentTime: TimeInterval
    public var duration: TimeInterval
    public var displayedTime: TimeInterval
    public var displayedDuration: TimeInterval
    public var playbackRate: Double

    public var sleepTimer: SleepTimerState?
    public var sleepTimerRemaining: TimeInterval?
    public var canCreateBookmark: Bool
    public var routeName: String?
    public var routeSymbol: String?

    public var skipBackwardInterval: Int
    public var skipForwardInterval: Int
    public var playbackRatePresets: [Double]

    /// When the state was captured; used to extrapolate the position while playing.
    public var capturedAt: Date

    public static let maximumChapterCount = 400

    public init(itemID: ItemIdentifier, title: String, subtitle: String?, chapterTitle: String?, chapterIndex: Int?, chapters: [Chapter], isPlaying: Bool, isBuffering: Bool, currentTime: TimeInterval, duration: TimeInterval, displayedTime: TimeInterval, displayedDuration: TimeInterval, playbackRate: Double, sleepTimer: SleepTimerState?, sleepTimerRemaining: TimeInterval?, canCreateBookmark: Bool, routeName: String?, routeSymbol: String?, skipBackwardInterval: Int, skipForwardInterval: Int, playbackRatePresets: [Double], capturedAt: Date = .now) {
        self.itemID = itemID
        self.title = title
        self.subtitle = subtitle
        self.chapterTitle = chapterTitle
        self.chapterIndex = chapterIndex
        self.chapters = Array(chapters.prefix(Self.maximumChapterCount))
        self.isPlaying = isPlaying
        self.isBuffering = isBuffering
        self.currentTime = currentTime
        self.duration = duration
        self.displayedTime = displayedTime
        self.displayedDuration = displayedDuration
        self.playbackRate = playbackRate
        self.sleepTimer = sleepTimer
        self.sleepTimerRemaining = sleepTimerRemaining
        self.canCreateBookmark = canCreateBookmark
        self.routeName = routeName
        self.routeSymbol = routeSymbol
        self.skipBackwardInterval = skipBackwardInterval
        self.skipForwardInterval = skipForwardInterval
        self.playbackRatePresets = playbackRatePresets
        self.capturedAt = capturedAt
    }

    /// Seconds of media played since the state was captured (0 while paused).
    public func elapsedMedia(at date: Date) -> TimeInterval {
        guard isPlaying, !isBuffering else { return 0 }
        return max(0, date.timeIntervalSince(capturedAt)) * playbackRate
    }

    /// Absolute position extrapolated to `date`.
    public func currentTime(at date: Date) -> TimeInterval {
        min(duration, currentTime + elapsedMedia(at: date))
    }

    /// Scrubber position extrapolated to `date`.
    public func displayedTime(at date: Date) -> TimeInterval {
        min(displayedDuration, displayedTime + elapsedMedia(at: date))
    }

    /// Remaining real time of the sleep timer at `date`.
    public func sleepTimerRemaining(at date: Date) -> TimeInterval? {
        guard let sleepTimerRemaining else { return nil }
        guard isPlaying else { return sleepTimerRemaining }
        return max(0, sleepTimerRemaining - date.timeIntervalSince(capturedAt))
    }

    /// Progress of the whole item (0...1).
    public var progress: Double {
        duration > 0 ? min(1, max(0, currentTime / duration)) : 0
    }
}

// MARK: - Commands

/// Remote commands the watch sends to the iPhone player.
public enum WatchCommand: Codable, Sendable, Hashable {
    case play
    case pause
    case togglePlayPause
    case skipForward(TimeInterval?)
    case skipBackward(TimeInterval?)
    case nextChapter
    case previousChapter
    /// Seeks to the chapter with the given `Chapter.id`.
    case seekToChapter(Int)
    /// Seeks relative to the current chapter (scrubber position).
    case seekToDisplayedTime(TimeInterval)
    case setPlaybackRate(Double)
    case cyclePlaybackRate
    case setSleepTimer(SleepTimerPreset)
    /// Sleep at the end of the chapter with the given `Chapter.id`.
    case sleepAtEndOfChapter(Int)
    case extendSleepTimer
    case adjustSleepTimer(Int)
    case cancelSleepTimer
    case createBookmark(note: String?)
    case playItem(ItemIdentifier, at: TimeInterval?)
    case resumeLastPlayed
    case stop
}

/// Why a remote command failed (localized on the receiving device).
public enum WatchCommandFailure: String, Codable, Sendable, Hashable {
    case nothingPlaying
    case notPlayable
    case downloadInProgress
    case itemUnavailable
    case bookmarkUnsupported
    case failed
}

public struct WatchCommandResult: Codable, Sendable, Hashable {
    public var failure: WatchCommandFailure?
    public var state: WatchNowPlayingState?

    public init(failure: WatchCommandFailure? = nil, state: WatchNowPlayingState?) {
        self.failure = failure
        self.state = state
    }
}

// MARK: - Context

/// Latest phone state, delivered through the application context (survives the watch app not running).
public struct WatchPhoneContext: Codable, Sendable, Hashable {
    public var nowPlaying: WatchNowPlayingState?
    /// The phone's widget snapshot (Listen Now, listened today, goal).
    public var snapshot: SharedSnapshot?
    public var sentAt: Date

    public init(nowPlaying: WatchNowPlayingState?, snapshot: SharedSnapshot?, sentAt: Date = .now) {
        self.nowPlaying = nowPlaying
        self.snapshot = snapshot
        self.sentAt = sentAt
    }
}

// MARK: - Envelope

public enum WatchSyncMessage: Codable, Sendable, Hashable {
    /// Watch → iPhone: please send all connections and tokens. Reply: `.credentials`.
    case credentialsRequest
    /// Connections + tokens (reply, or pushed whenever tokens change on either side).
    case credentials(WatchCredentials)
    /// Watch → iPhone: please send the current player state. Reply: `.nowPlayingState`.
    case nowPlayingRequest
    /// iPhone → watch: player state (`nil` = idle).
    case nowPlayingState(WatchNowPlayingState?)
    /// Watch → iPhone: remote command. Reply: `.commandResult`.
    case command(WatchCommand)
    case commandResult(WatchCommandResult)
    /// iPhone → watch: application context / complication user info.
    case context(WatchPhoneContext)
    /// Generic acknowledgement.
    case acknowledged

    static let payloadKey = "hearth.v1"

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    /// WatchConnectivity dictionary representation.
    public func dictionary() throws -> [String: Any] {
        [Self.payloadKey: try Self.encoder.encode(self)]
    }

    /// Decodes a WatchConnectivity dictionary; `nil` for foreign or malformed payloads.
    public init?(dictionary: [String: Any]) {
        guard let data = dictionary[Self.payloadKey] as? Data,
              let message = try? Self.decoder.decode(WatchSyncMessage.self, from: data) else {
            return nil
        }
        self = message
    }
}
