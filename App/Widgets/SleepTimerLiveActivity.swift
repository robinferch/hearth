import ActivityKit
import AppIntents
import HearthData
import HearthIntents
import HearthModel
import HearthUI
import SwiftUI
import WidgetKit

typealias SleepTimerState = SleepTimerActivityAttributes.ContentState

struct SleepTimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SleepTimerActivityAttributes.self) { context in
            SleepTimerLockScreenView(attributes: context.attributes, state: context.state)
                .tint(context.attributes.tint.color)
                .activityBackgroundTint(nil)
                .widgetURL(itemURL(context.attributes, state: context.state))
        } dynamicIsland: { context in
            let state = context.state
            let tint = context.attributes.tint.color
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    SleepTimerCover(file: context.attributes.coverFile(state))
                        .frame(width: 52, height: 52)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    SleepTimerCountdown(state: state)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(maxWidth: 110, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.title(state))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        SleepTimerStatusText(state: state)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    SleepTimerButtons(state: state)
                        .tint(tint)
                        .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: state.isExpired ? "moon.zzz.fill" : "moon.zzz")
                    .foregroundStyle(tint)
            } compactTrailing: {
                SleepTimerCountdown(state: state, compact: true)
                    .foregroundStyle(tint)
                    .frame(maxWidth: 52)
            } minimal: {
                Image(systemName: "moon.zzz.fill")
                    .foregroundStyle(tint)
            }
            .widgetURL(itemURL(context.attributes, state: context.state))
            .keylineTint(tint)
        }
        .supplementalActivityFamilies([.small, .medium])
    }

    private func itemURL(_ attributes: SleepTimerActivityAttributes, state: SleepTimerState) -> URL? {
        ItemIdentifier(attributes.itemID(state)).map { WidgetData.url(host: "item", id: $0) }
    }
}

/// Lock Screen / StandBy / Watch Smart Stack presentation.
struct SleepTimerLockScreenView: View {
    let attributes: SleepTimerActivityAttributes
    let state: SleepTimerState

    @Environment(\.activityFamily) private var activityFamily

    var body: some View {
        if activityFamily == .small {
            // Apple Watch Smart Stack / CarPlay.
            HStack {
                Image(systemName: "moon.zzz.fill")
                    .foregroundStyle(.tint)
                SleepTimerCountdown(state: state)
                    .font(.headline)
            }
        } else {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    SleepTimerCover(file: attributes.coverFile(state))
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Label {
                            SleepTimerStatusText(state: state)
                        } icon: {
                            Image(systemName: state.isExpired ? "moon.zzz.fill" : "moon.zzz")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                        Text(attributes.title(state))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    SleepTimerCountdown(state: state)
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 120, alignment: .trailing)
                }
                SleepTimerButtons(state: state)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(14)
        }
    }
}

struct SleepTimerCover: View {
    let file: String?

    var body: some View {
        WidgetCover(data: file.flatMap(WidgetData.coverData), cornerRadius: 8, symbol: "moon.zzz")
    }
}

/// Countdown for running duration timers, static remaining time while paused, chapters otherwise.
struct SleepTimerCountdown: View {
    let state: SleepTimerState
    var compact = false

    var body: some View {
        if state.isExpired {
            Image(systemName: "pause.fill")
                .accessibilityLabel(Text("Paused"))
        } else {
            switch state.mode {
            case .duration:
                if state.isPlaying, let deadline = state.deadline, deadline > .now {
                    Text(timerInterval: Date.now...deadline, countsDown: true, showsHours: true)
                        .monospacedDigit()
                        .multilineTextAlignment(compact ? .trailing : .leading)
                } else {
                    Text((state.remaining ?? 0).clockFormatted)
                        .monospacedDigit()
                }
            case .chapters:
                if compact {
                    Text(state.chaptersRemaining ?? 1, format: .number)
                        .monospacedDigit()
                } else if state.isPlaying, let end = state.chapterEnd, end > .now, (state.chaptersRemaining ?? 1) == 1 {
                    Text(timerInterval: Date.now...end, countsDown: true, showsHours: true)
                        .monospacedDigit()
                } else {
                    chaptersText
                }
            }
        }
    }

    private var chaptersText: Text {
        let remaining = state.chaptersRemaining ?? 1
        return remaining == 1 ? Text("End of chapter") : Text("\(remaining) chapters")
    }
}

struct SleepTimerStatusText: View {
    let state: SleepTimerState

    var body: some View {
        if state.isExpired {
            Text("Sleep timer ended")
        } else if !state.isPlaying {
            Text("Sleep timer paused")
        } else {
            switch state.mode {
            case .duration:
                if let deadline = state.deadline {
                    Text("Sleeping at \(deadline.formatted(date: .omitted, time: .shortened))")
                } else {
                    Text("Sleep Timer")
                }
            case .chapters:
                if (state.chaptersRemaining ?? 1) == 1 {
                    Text("Sleeping at end of chapter")
                } else {
                    Text("Sleeping after \(state.chaptersRemaining ?? 1) chapters")
                }
            }
        }
    }
}

/// Extend / cancel (duration), −/+ chapter (chapters), resume (paused / expired).
struct SleepTimerButtons: View {
    let state: SleepTimerState

    var body: some View {
        HStack(spacing: 10) {
            if state.isExpired {
                Button(intent: ExtendSleepTimerIntent()) {
                    Label("Resume", systemImage: "play.fill")
                }
            } else {
                if !state.isPlaying {
                    Button(intent: ResumeIntent()) {
                        Label("Resume", systemImage: "play.fill")
                    }
                }
                switch state.mode {
                case .duration:
                    Button(intent: ExtendSleepTimerIntent()) {
                        Label("Extend", systemImage: "plus")
                    }
                case .chapters:
                    Button(intent: AdjustSleepTimerIntent(delta: -1)) {
                        Label("One chapter less", systemImage: "minus")
                    }
                    Button(intent: AdjustSleepTimerIntent(delta: 1)) {
                        Label("One chapter more", systemImage: "plus")
                    }
                }
                Button(intent: CancelSleepTimerIntent()) {
                    Label("Cancel", systemImage: "xmark")
                }
            }
        }
        .labelStyle(.iconOnly)
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
    }
}
