import Foundation

/// Where playback was started from; drives Up Next generation and rate/sleep-timer lookup.
public enum PlaybackOrigin: Hashable, Codable, Sendable {
    case none
    case series(ItemIdentifier)
    case podcast(ItemIdentifier)
    case collection(ItemIdentifier)
    case listenNow
    case carPlay

    public var groupingID: ItemIdentifier? {
        switch self {
        case .series(let id), .podcast(let id), .collection(let id): id
        default: nil
        }
    }
}

/// An active sleep timer.
public enum SleepTimerState: Hashable, Codable, Sendable {
    /// Fires at `deadline`; `original` is the configured length (used for extending).
    case duration(deadline: Date, original: TimeInterval)
    /// Fires at the end of the `remaining`-th chapter from now.
    case chapters(remaining: Int, original: Int)

    public var isChapterBased: Bool {
        if case .chapters = self { true } else { false }
    }
}

/// A sleep timer configuration that can be saved per item/grouping or chosen from presets.
public enum SleepTimerPreset: Hashable, Codable, Sendable {
    case minutes(Int)
    case chapters(Int)

    public static let endOfChapter = SleepTimerPreset.chapters(1)
}

/// Output route shown on the AirPlay button.
public struct AudioRoute: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case speaker
        case headphones
        case airPods
        case airPodsPro
        case airPodsMax
        case bluetooth
        case airPlay
        case homePod
        case homePodMini
        case appleTV
        case car
        case hdmi
        case lineOut
        case usb
    }

    public var name: String
    public var kind: Kind

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }

    public var systemImage: String {
        switch kind {
        case .speaker: "airplay.audio"
        case .headphones: "headphones"
        case .airPods: "airpods"
        case .airPodsPro: "airpods.pro"
        case .airPodsMax: "airpods.max"
        case .bluetooth: "hifispeaker"
        case .airPlay: "airplay.audio"
        case .homePod: "homepod"
        case .homePodMini: "homepod.mini"
        case .appleTV: "appletv"
        case .car: "car"
        case .hdmi: "tv"
        case .lineOut: "cable.connector"
        case .usb: "cable.connector"
        }
    }

    /// Whether this is a non-default route (tinted in the UI).
    public var isExternal: Bool { kind != .speaker }

    public static let speaker = AudioRoute(name: "iPhone", kind: .speaker)
}
