import AppIntents
import Foundation
import HearthData
import HearthModel
import HearthPlayback

public enum SleepTimerUnit: String, AppEnum {
    case seconds
    case minutes
    case hours
    case chapters

    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("Unit", table: "System"))
    public static let caseDisplayRepresentations: [SleepTimerUnit: DisplayRepresentation] = [
        .seconds: DisplayRepresentation(title: LocalizedStringResource("seconds", table: "System")),
        .minutes: DisplayRepresentation(title: LocalizedStringResource("minutes", table: "System")),
        .hours: DisplayRepresentation(title: LocalizedStringResource("hours", table: "System")),
        .chapters: DisplayRepresentation(title: LocalizedStringResource("chapters", table: "System")),
    ]
}

/// Sleep timer helpers shared with the Control Center control and the Live Activity.
@MainActor
public enum SleepTimerActions {
    /// Remembers the last duration timer so the control can re-enable it.
    static let lastMinutesKey = "intents.lastSleepTimerMinutes"

    /// Set by the app: brings the sleep timer Live Activity up to date right away. Timer intents call it from
    /// `perform`, the only moment the app may start a Live Activity while it is in the background.
    public static var liveActivityUpdater: (@MainActor () async -> Void)?

    static func updateLiveActivity() async {
        await liveActivityUpdater?()
    }

    /// Called by the app whenever the timer changes (to remember the last used duration).
    public static func remember(_ state: SleepTimerState?) {
        guard case .duration(_, let original)? = state, original > 0 else { return }
        AppGroup.defaults.set(max(1, Int((original / 60).rounded())), forKey: lastMinutesKey)
    }

    /// The preset used by the sleep timer control: end of chapter when the item has chapters, otherwise the last
    /// used duration (falling back to the first configured preset).
    static func defaultPreset(for player: AudioPlayer) -> SleepTimerPreset {
        if !player.chapters.isEmpty {
            return .endOfChapter
        }
        let stored = AppGroup.defaults.integer(forKey: lastMinutesKey)
        if stored > 0 {
            return .minutes(stored)
        }
        return .minutes(AppSettings.shared.sleepTimerPresets.first ?? 30)
    }

    static func preset(amount: Int, unit: SleepTimerUnit) -> SleepTimerPreset {
        let amount = max(1, amount)
        return switch unit {
        // The player's timer has minute granularity; seconds are rounded up.
        case .seconds: .minutes(max(1, Int((Double(amount) / 60).rounded(.up))))
        case .minutes: .minutes(amount)
        case .hours: .minutes(amount * 60)
        case .chapters: .chapters(amount)
        }
    }
}

public struct SetSleepTimerIntent: AudioPlaybackIntent {
    public static let title = LocalizedStringResource("Set Sleep Timer", table: "System")
    public static let description = IntentDescription(LocalizedStringResource("Pauses playback after a duration or a number of chapters.", table: "System"))

    @Parameter(title: LocalizedStringResource("Amount", table: "System"), default: 30, inclusiveRange: (1, 6000))
    public var amount: Int

    @Parameter(title: LocalizedStringResource("Unit", table: "System"), default: .minutes)
    public var unit: SleepTimerUnit

    public static var parameterSummary: some ParameterSummary {
        Summary("Set a sleep timer for \(\.$amount) \(\.$unit)", table: "System")
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let player = try PlaybackActions.requireActive()
        if unit == .chapters, player.chapters.isEmpty {
            throw HearthIntentError.noChapters
        }
        let preset = SleepTimerActions.preset(amount: amount, unit: unit)
        player.setSleepTimer(preset)
        await SleepTimerActions.updateLiveActivity()
        let text = switch preset {
        case .minutes(let minutes): IntentSupport.text("Sleep timer set for \(Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide))).")
        case .chapters(1): IntentSupport.text("Playback pauses at the end of the chapter.")
        case .chapters(let chapters): IntentSupport.text("Playback pauses after \(chapters) chapters.")
        }
        return .result(dialog: IntentSupport.dialog(text))
    }
}

public struct ExtendSleepTimerIntent: AudioPlaybackIntent {
    public static let title = LocalizedStringResource("Extend Sleep Timer", table: "System")
    public static let description = IntentDescription(LocalizedStringResource("Extends the sleep timer, or restarts it shortly after it ended.", table: "System"))

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        let player = PlaybackActions.player
        let wasExpired = player.sleepTimer == nil
        player.extendSleepTimer()
        if wasExpired, player.sleepTimer != nil, !player.isPlaying {
            player.resume()
        }
        await SleepTimerActions.updateLiveActivity()
        return .result()
    }
}

public struct CancelSleepTimerIntent: AudioPlaybackIntent {
    public static let title = LocalizedStringResource("Cancel Sleep Timer", table: "System")
    public static let description = IntentDescription(LocalizedStringResource("Turns off the sleep timer.", table: "System"))

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        PlaybackActions.player.cancelSleepTimer()
        await SleepTimerActions.updateLiveActivity()
        return .result()
    }
}

/// ±1 minute / ±1 chapter (Live Activity buttons).
public struct AdjustSleepTimerIntent: AudioPlaybackIntent {
    public static let title = LocalizedStringResource("Adjust Sleep Timer", table: "System")
    public static let isDiscoverable = false

    @Parameter(title: LocalizedStringResource("Change", table: "System"), default: 1)
    public var delta: Int

    public init() {}

    public init(delta: Int) {
        self.delta = delta
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        PlaybackActions.player.adjustSleepTimer(by: delta)
        await SleepTimerActions.updateLiveActivity()
        return .result()
    }
}

/// Backs the sleep timer control: on = end of chapter / last duration, off = cancel.
public struct SetSleepTimerEnabledIntent: SetValueIntent, AudioPlaybackIntent {
    public static let title = LocalizedStringResource("Toggle Sleep Timer", table: "System")
    public static let isDiscoverable = false

    @Parameter(title: LocalizedStringResource("Enabled", table: "System"))
    public var value: Bool

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        let player = PlaybackActions.player
        if value {
            guard player.isActive else { throw HearthIntentError.nothingPlaying }
            player.setSleepTimer(SleepTimerActions.defaultPreset(for: player))
        } else {
            player.cancelSleepTimer()
        }
        await SleepTimerActions.updateLiveActivity()
        return .result()
    }
}

#if os(iOS)
// Live Activity intents run in the app and may start the sleep timer activity from the background.
extension SetSleepTimerIntent: LiveActivityIntent {}
extension SetSleepTimerEnabledIntent: LiveActivityIntent {}
extension ExtendSleepTimerIntent: LiveActivityIntent {}
extension CancelSleepTimerIntent: LiveActivityIntent {}
extension AdjustSleepTimerIntent: LiveActivityIntent {}
#endif
