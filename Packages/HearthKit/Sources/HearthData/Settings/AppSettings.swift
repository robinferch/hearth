import Foundation
import HearthModel
import Observation

/// Global user preferences, persisted in the app group's user defaults.
@MainActor
@Observable
public final class AppSettings {
    public static let shared = AppSettings()

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults

        defaultPlaybackRate = defaults.value(forKey: Key.defaultPlaybackRate) as? Double ?? 1.0
        playbackRatePresets = defaults.array(forKey: Key.playbackRatePresets) as? [Double] ?? [0.9, 1.0, 1.3, 1.6, 2.0]
        playbackRateStepUp = defaults.value(forKey: Key.playbackRateStepUp) as? Double ?? 0.1
        playbackRateStepDown = defaults.value(forKey: Key.playbackRateStepDown) as? Double ?? 0.1
        skipBackwardInterval = defaults.value(forKey: Key.skipBackwardInterval) as? Int ?? 15
        skipForwardInterval = defaults.value(forKey: Key.skipForwardInterval) as? Int ?? 30
        smartRewind = defaults.value(forKey: Key.smartRewind) as? Bool ?? true
        chapterRelativeProgress = defaults.value(forKey: Key.chapterRelativeProgress) as? Bool ?? true
        lockSeekBar = defaults.value(forKey: Key.lockSeekBar) as? Bool ?? false
        replaceVolumeWithTotalProgress = defaults.value(forKey: Key.replaceVolumeWithTotalProgress) as? Bool ?? false
        remoteNextPreviousSkipsChapters = defaults.value(forKey: Key.remoteNextPreviousSkipsChapters) as? Bool ?? true
        generateUpNext = defaults.value(forKey: Key.generateUpNext) as? Bool ?? true

        sleepTimerPresets = defaults.array(forKey: Key.sleepTimerPresets) as? [Int] ?? [5, 10, 15, 20, 25, 30, 45, 60, 75, 90]
        sleepTimerExtendByPrevious = defaults.value(forKey: Key.sleepTimerExtendByPrevious) as? Bool ?? true
        sleepTimerExtendMinutes = defaults.value(forKey: Key.sleepTimerExtendMinutes) as? Int ?? 20
        sleepTimerExtendChapters = defaults.value(forKey: Key.sleepTimerExtendChapters) as? Int ?? 1
        sleepTimerFadeOut = defaults.value(forKey: Key.sleepTimerFadeOut) as? Bool ?? true
        shakeExtendsSleepTimer = defaults.value(forKey: Key.shakeExtendsSleepTimer) as? Bool ?? false
        playExtendsSleepTimer = defaults.value(forKey: Key.playExtendsSleepTimer) as? Bool ?? false

        tintColor = (defaults.string(forKey: Key.tintColor)).flatMap(TintColor.init(rawValue:)) ?? .hearth
        colorScheme = (defaults.string(forKey: Key.colorScheme)).flatMap(ColorSchemePreference.init(rawValue:)) ?? .system
        serifTitles = defaults.value(forKey: Key.serifTitles) as? Bool ?? true
        showProgressPercent = defaults.value(forKey: Key.showProgressPercent) as? Bool ?? false
        highQualityImages = defaults.value(forKey: Key.highQualityImages) as? Bool ?? false

        groupBooksInSeries = defaults.value(forKey: Key.groupBooksInSeries) as? Bool ?? true
        showSingleEntrySeries = defaults.value(forKey: Key.showSingleEntrySeries) as? Bool ?? false
        showAuthorsRow = defaults.value(forKey: Key.showAuthorsRow) as? Bool ?? false
        hideDiscoverRow = defaults.value(forKey: Key.hideDiscoverRow) as? Bool ?? false
        defaultEpisodeSort = (defaults.string(forKey: Key.defaultEpisodeSort)).flatMap(EpisodeSortOrder.init(rawValue:)) ?? .released
        defaultEpisodeSortDirection = (defaults.string(forKey: Key.defaultEpisodeSortDirection)).flatMap(SortDirection.init(rawValue:)) ?? .descending

        allowCellularDownloads = defaults.value(forKey: Key.allowCellularDownloads) as? Bool ?? false
        removeFinishedDownloads = defaults.value(forKey: Key.removeFinishedDownloads) as? Bool ?? true
        autoDownloadsEnabled = defaults.value(forKey: Key.autoDownloadsEnabled) as? Bool ?? true
        autoDownloadListenNow = defaults.value(forKey: Key.autoDownloadListenNow) as? Bool ?? false

        dailyGoalMinutes = defaults.value(forKey: Key.dailyGoalMinutes) as? Int ?? 30
        showRemainingTime = defaults.value(forKey: Key.showRemainingTime) as? Bool ?? false

        carPlayShowListenNow = defaults.value(forKey: Key.carPlayShowListenNow) as? Bool ?? true
        carPlayLibraries = defaults.stringArray(forKey: Key.carPlayLibraries) ?? []
        carPlayShowOtherLibraries = defaults.value(forKey: Key.carPlayShowOtherLibraries) as? Bool ?? true
    }

    // MARK: Playback

    public var defaultPlaybackRate: Double { didSet { defaults.set(defaultPlaybackRate, forKey: Key.defaultPlaybackRate) } }
    public var playbackRatePresets: [Double] { didSet { defaults.set(playbackRatePresets, forKey: Key.playbackRatePresets) } }
    public var playbackRateStepUp: Double { didSet { defaults.set(playbackRateStepUp, forKey: Key.playbackRateStepUp) } }
    public var playbackRateStepDown: Double { didSet { defaults.set(playbackRateStepDown, forKey: Key.playbackRateStepDown) } }
    public var skipBackwardInterval: Int { didSet { defaults.set(skipBackwardInterval, forKey: Key.skipBackwardInterval) } }
    public var skipForwardInterval: Int { didSet { defaults.set(skipForwardInterval, forKey: Key.skipForwardInterval) } }
    public var smartRewind: Bool { didSet { defaults.set(smartRewind, forKey: Key.smartRewind) } }
    public var chapterRelativeProgress: Bool { didSet { defaults.set(chapterRelativeProgress, forKey: Key.chapterRelativeProgress) } }
    public var lockSeekBar: Bool { didSet { defaults.set(lockSeekBar, forKey: Key.lockSeekBar) } }
    public var replaceVolumeWithTotalProgress: Bool { didSet { defaults.set(replaceVolumeWithTotalProgress, forKey: Key.replaceVolumeWithTotalProgress) } }
    public var remoteNextPreviousSkipsChapters: Bool { didSet { defaults.set(remoteNextPreviousSkipsChapters, forKey: Key.remoteNextPreviousSkipsChapters) } }
    public var generateUpNext: Bool { didSet { defaults.set(generateUpNext, forKey: Key.generateUpNext) } }

    public static let skipIntervalOptions = [5, 10, 15, 30, 45, 60, 75, 90]

    // MARK: Sleep timer

    /// Minutes.
    public var sleepTimerPresets: [Int] { didSet { defaults.set(sleepTimerPresets, forKey: Key.sleepTimerPresets) } }
    public var sleepTimerExtendByPrevious: Bool { didSet { defaults.set(sleepTimerExtendByPrevious, forKey: Key.sleepTimerExtendByPrevious) } }
    public var sleepTimerExtendMinutes: Int { didSet { defaults.set(sleepTimerExtendMinutes, forKey: Key.sleepTimerExtendMinutes) } }
    public var sleepTimerExtendChapters: Int { didSet { defaults.set(sleepTimerExtendChapters, forKey: Key.sleepTimerExtendChapters) } }
    public var sleepTimerFadeOut: Bool { didSet { defaults.set(sleepTimerFadeOut, forKey: Key.sleepTimerFadeOut) } }
    public var shakeExtendsSleepTimer: Bool { didSet { defaults.set(shakeExtendsSleepTimer, forKey: Key.shakeExtendsSleepTimer) } }
    public var playExtendsSleepTimer: Bool { didSet { defaults.set(playExtendsSleepTimer, forKey: Key.playExtendsSleepTimer) } }

    // MARK: Appearance

    public var tintColor: TintColor { didSet { defaults.set(tintColor.rawValue, forKey: Key.tintColor) } }
    public var colorScheme: ColorSchemePreference { didSet { defaults.set(colorScheme.rawValue, forKey: Key.colorScheme) } }
    public var serifTitles: Bool { didSet { defaults.set(serifTitles, forKey: Key.serifTitles) } }
    public var showProgressPercent: Bool { didSet { defaults.set(showProgressPercent, forKey: Key.showProgressPercent) } }
    public var highQualityImages: Bool { didSet { defaults.set(highQualityImages, forKey: Key.highQualityImages) } }

    // MARK: Library

    public var groupBooksInSeries: Bool { didSet { defaults.set(groupBooksInSeries, forKey: Key.groupBooksInSeries) } }
    public var showSingleEntrySeries: Bool { didSet { defaults.set(showSingleEntrySeries, forKey: Key.showSingleEntrySeries) } }
    public var showAuthorsRow: Bool { didSet { defaults.set(showAuthorsRow, forKey: Key.showAuthorsRow) } }
    public var hideDiscoverRow: Bool { didSet { defaults.set(hideDiscoverRow, forKey: Key.hideDiscoverRow) } }
    public var defaultEpisodeSort: EpisodeSortOrder { didSet { defaults.set(defaultEpisodeSort.rawValue, forKey: Key.defaultEpisodeSort) } }
    public var defaultEpisodeSortDirection: SortDirection { didSet { defaults.set(defaultEpisodeSortDirection.rawValue, forKey: Key.defaultEpisodeSortDirection) } }

    // MARK: Downloads

    public var allowCellularDownloads: Bool { didSet { defaults.set(allowCellularDownloads, forKey: Key.allowCellularDownloads) } }
    public var removeFinishedDownloads: Bool { didSet { defaults.set(removeFinishedDownloads, forKey: Key.removeFinishedDownloads) } }
    public var autoDownloadsEnabled: Bool { didSet { defaults.set(autoDownloadsEnabled, forKey: Key.autoDownloadsEnabled) } }
    public var autoDownloadListenNow: Bool { didSet { defaults.set(autoDownloadListenNow, forKey: Key.autoDownloadListenNow) } }

    // MARK: Misc

    public var dailyGoalMinutes: Int { didSet { defaults.set(dailyGoalMinutes, forKey: Key.dailyGoalMinutes) } }
    /// Player trailing label shows remaining instead of total time.
    public var showRemainingTime: Bool { didSet { defaults.set(showRemainingTime, forKey: Key.showRemainingTime) } }

    // MARK: CarPlay

    public var carPlayShowListenNow: Bool { didSet { defaults.set(carPlayShowListenNow, forKey: Key.carPlayShowListenNow) } }
    /// `LibraryIdentifier.description` values, ordered.
    public var carPlayLibraries: [String] { didSet { defaults.set(carPlayLibraries, forKey: Key.carPlayLibraries) } }
    public var carPlayShowOtherLibraries: Bool { didSet { defaults.set(carPlayShowOtherLibraries, forKey: Key.carPlayShowOtherLibraries) } }

    public func resetPlaybackRates() {
        defaultPlaybackRate = 1.0
        playbackRatePresets = [0.9, 1.0, 1.3, 1.6, 2.0]
        playbackRateStepUp = 0.1
        playbackRateStepDown = 0.1
    }

    public func resetSleepTimer() {
        sleepTimerPresets = [5, 10, 15, 20, 25, 30, 45, 60, 75, 90]
        sleepTimerExtendByPrevious = true
        sleepTimerExtendMinutes = 20
        sleepTimerExtendChapters = 1
    }

    enum Key {
        static let defaultPlaybackRate = "defaultPlaybackRate"
        static let playbackRatePresets = "playbackRatePresets"
        static let playbackRateStepUp = "playbackRateStepUp"
        static let playbackRateStepDown = "playbackRateStepDown"
        static let skipBackwardInterval = "skipBackwardInterval"
        static let skipForwardInterval = "skipForwardInterval"
        static let smartRewind = "smartRewind"
        static let chapterRelativeProgress = "chapterRelativeProgress"
        static let lockSeekBar = "lockSeekBar"
        static let replaceVolumeWithTotalProgress = "replaceVolumeWithTotalProgress"
        static let remoteNextPreviousSkipsChapters = "remoteNextPreviousSkipsChapters"
        static let generateUpNext = "generateUpNext"
        static let sleepTimerPresets = "sleepTimerPresets"
        static let sleepTimerExtendByPrevious = "sleepTimerExtendByPrevious"
        static let sleepTimerExtendMinutes = "sleepTimerExtendMinutes"
        static let sleepTimerExtendChapters = "sleepTimerExtendChapters"
        static let sleepTimerFadeOut = "sleepTimerFadeOut"
        static let shakeExtendsSleepTimer = "shakeExtendsSleepTimer"
        static let playExtendsSleepTimer = "playExtendsSleepTimer"
        static let tintColor = "tintColor"
        static let colorScheme = "colorScheme"
        static let serifTitles = "serifTitles"
        static let showProgressPercent = "showProgressPercent"
        static let highQualityImages = "highQualityImages"
        static let groupBooksInSeries = "groupBooksInSeries"
        static let showSingleEntrySeries = "showSingleEntrySeries"
        static let showAuthorsRow = "showAuthorsRow"
        static let hideDiscoverRow = "hideDiscoverRow"
        static let defaultEpisodeSort = "defaultEpisodeSort"
        static let defaultEpisodeSortDirection = "defaultEpisodeSortDirection"
        static let allowCellularDownloads = "allowCellularDownloads"
        static let removeFinishedDownloads = "removeFinishedDownloads"
        static let autoDownloadsEnabled = "autoDownloadsEnabled"
        static let autoDownloadListenNow = "autoDownloadListenNow"
        static let dailyGoalMinutes = "dailyGoalMinutes"
        static let showRemainingTime = "showRemainingTime"
        static let carPlayShowListenNow = "carPlayShowListenNow"
        static let carPlayLibraries = "carPlayLibraries"
        static let carPlayShowOtherLibraries = "carPlayShowOtherLibraries"
    }
}

public enum TintColor: String, Codable, Sendable, CaseIterable {
    case hearth
    case yellow
    case red
    case pink
    case purple
    case blue
    case teal
    case mint
    case green
    case graphite
}

public enum ColorSchemePreference: String, Codable, Sendable, CaseIterable {
    case system
    case light
    case dark
}
