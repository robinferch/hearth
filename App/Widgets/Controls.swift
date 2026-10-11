import AppIntents
import HearthData
import HearthIntents
import HearthModel
import SwiftUI
import WidgetKit

// Control Center / Lock Screen / Action button controls. Values come from the shared snapshot; the app reloads
// all controls whenever it writes the snapshot.

enum ControlKind {
    static let playPause = "me.robinferch.hearth.control.playPause"
    static let skipBackward = "me.robinferch.hearth.control.skipBackward"
    static let skipForward = "me.robinferch.hearth.control.skipForward"
    static let sleepTimer = "me.robinferch.hearth.control.sleepTimer"
    static let search = "me.robinferch.hearth.control.search"
}

struct PlaybackControlValue {
    var isOn: Bool
    var title: String?
}

struct PlayingValueProvider: ControlValueProvider {
    var previewValue: PlaybackControlValue { PlaybackControlValue(isOn: false, title: nil) }

    func currentValue() async throws -> PlaybackControlValue {
        let snapshot = SharedSnapshotStore.read()
        return PlaybackControlValue(isOn: snapshot.isPlaying, title: snapshot.nowPlaying?.title)
    }
}

struct SleepTimerValueProvider: ControlValueProvider {
    var previewValue: PlaybackControlValue { PlaybackControlValue(isOn: false, title: nil) }

    func currentValue() async throws -> PlaybackControlValue {
        let snapshot = SharedSnapshotStore.read()
        let title: String? = switch snapshot.sleepTimer {
        case .duration(let deadline, _)?:
            String(localized: "Until \(deadline.formatted(date: .omitted, time: .shortened))")
        case .chapters(1, _)?:
            String(localized: "End of chapter")
        case .chapters(let remaining, _)?:
            String(localized: "\(remaining) chapters")
        case nil:
            nil
        }
        return PlaybackControlValue(isOn: snapshot.sleepTimer != nil, title: title)
    }
}

struct PlayPauseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: ControlKind.playPause, provider: PlayingValueProvider()) { value in
            ControlWidgetToggle(isOn: value.isOn, action: SetPlayingIntent()) {
                Label {
                    Text(value.title ?? String(localized: "Hearth"))
                } icon: {
                    Image(systemName: "headphones")
                }
            } valueLabel: { isOn in
                Label(isOn ? "Playing" : "Paused", systemImage: isOn ? "pause.fill" : "play.fill")
            }
        }
        .displayName("Play/Pause")
        .description("Play or pause the current audiobook or episode.")
    }
}

struct SkipBackwardControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: ControlKind.skipBackward) {
            ControlWidgetButton(action: SkipBackwardIntent(seconds: nil)) {
                Label("Skip Backward", systemImage: "gobackward")
            }
        }
        .displayName("Skip Backward")
        .description("Skip backward by your skip interval.")
    }
}

struct SkipForwardControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: ControlKind.skipForward) {
            ControlWidgetButton(action: SkipForwardIntent(seconds: nil)) {
                Label("Skip Forward", systemImage: "goforward")
            }
        }
        .displayName("Skip Forward")
        .description("Skip forward by your skip interval.")
    }
}

struct SleepTimerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: ControlKind.sleepTimer, provider: SleepTimerValueProvider()) { value in
            ControlWidgetToggle(isOn: value.isOn, action: SetSleepTimerEnabledIntent()) {
                Label {
                    Text("Sleep Timer")
                } icon: {
                    Image(systemName: "moon.zzz")
                }
            } valueLabel: { isOn in
                Label {
                    Text(isOn ? (value.title ?? String(localized: "On")) : String(localized: "Off"))
                } icon: {
                    Image(systemName: isOn ? "moon.zzz.fill" : "moon.zzz")
                }
            }
        }
        .displayName("Sleep Timer")
        .description("Pause at the end of the chapter, or after your last sleep timer duration.")
    }
}

struct SearchControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: ControlKind.search) {
            ControlWidgetButton(action: OpenSearchIntent()) {
                Label("Search Hearth", systemImage: "magnifyingglass")
            }
        }
        .displayName("Search Hearth")
        .description("Open the search in Hearth.")
    }
}
