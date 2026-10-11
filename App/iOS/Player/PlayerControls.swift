import HearthData
import HearthModel
import HearthPlayback
import HearthUI
import SwiftUI
import TipKit

// MARK: - Scrubber

/// Chapter scrubber with elapsed / chapter title (or remaining at rate) / duration ↔ −remaining labels.
struct PlayerScrubberSection: View {
    @State private var preview: TimeInterval?

    private var player: AudioPlayer { .shared }
    private var settings: AppSettings { .shared }

    var body: some View {
        let time = preview ?? player.displayedTime
        let total = player.displayedDuration
        VStack(spacing: 6) {
            PlaybackScrubber(
                value: player.displayedTime,
                total: total,
                isLocked: settings.lockSeekBar,
                onScrub: { preview = $0 },
                onCommit: { value in
                    Task { await player.seek(toDisplayedTime: value) }
                }
            )
            .opacity(settings.lockSeekBar ? 0.6 : 1)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(HearthFormat.clock(time))
                    .frame(minWidth: 64, alignment: .leading)
                Spacer(minLength: 0)
                centerLabel(time: time, total: total)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                Spacer(minLength: 0)
                Button {
                    settings.showRemainingTime.toggle()
                } label: {
                    Text(trailingLabel(time: time, total: total))
                        .frame(minWidth: 64, alignment: .trailing)
                        .contentTransition(.numericText())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(settings.showRemainingTime ? String(localized: "Remaining time", table: "Player") : String(localized: "Duration", table: "Player"))
                .accessibilityHint(String(localized: "Toggles between duration and remaining time", table: "Player"))
            }
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .sensoryFeedback(.selection, trigger: settings.showRemainingTime)
    }

    @ViewBuilder
    private func centerLabel(time: TimeInterval, total: TimeInterval) -> some View {
        if let chapter = player.currentChapter, player.chapters.count > 1 {
            Text(chapter.title)
                .foregroundStyle(.primary.opacity(0.8))
        } else {
            Text(HearthFormat.remaining(player.remainingTime))
        }
    }

    private func trailingLabel(time: TimeInterval, total: TimeInterval) -> String {
        if settings.showRemainingTime {
            let remaining = max(0, total - time) / max(player.playbackRate, 0.01)
            return "-" + HearthFormat.clock(remaining)
        }
        return HearthFormat.clock(total)
    }
}

/// Whole-item progress slider (replaces the volume slider when `replaceVolumeWithTotalProgress` is on).
struct TotalProgressSlider: View {
    private var player: AudioPlayer { .shared }

    var body: some View {
        HStack(spacing: 12) {
            Text(HearthFormat.percent(player.duration > 0 ? player.currentTime / player.duration : 0))
                .frame(minWidth: 40, alignment: .leading)
            PlaybackScrubber(value: player.currentTime, total: player.duration, isLocked: AppSettings.shared.lockSeekBar) { value in
                Task { await player.seek(to: value) }
            }
            Text(HearthFormat.remaining(player.remainingTime))
                .frame(minWidth: 70, alignment: .trailing)
        }
        .font(.caption2.weight(.medium))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
}

// MARK: - Transport

struct TransportControls: View {
    var compact = false

    @ScaledMetric(relativeTo: .largeTitle) private var playSize: CGFloat = 44
    @ScaledMetric(relativeTo: .title) private var skipSize: CGFloat = 30

    private var player: AudioPlayer { .shared }

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            SkipButton(forward: false, size: compact ? skipSize * 0.8 : skipSize)
                .popoverTip(PlayerTips.skipLongPress, arrowEdge: .top)
            Spacer(minLength: 0)
            PlayPauseButton(size: compact ? playSize * 0.8 : playSize)
            Spacer(minLength: 0)
            SkipButton(forward: true, size: compact ? skipSize * 0.8 : skipSize)
            Spacer(minLength: 0)
        }
    }
}

struct PlayPauseButton: View {
    let size: CGFloat

    private var player: AudioPlayer { .shared }

    var body: some View {
        let playing = player.isPlaying
        Button {
            player.togglePlayPause()
        } label: {
            ZStack {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: size, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace.downUp))
                    .symbolEffect(.pulse, options: .repeating, isActive: player.isBuffering)
                if player.isBuffering || player.isBusy {
                    Circle()
                        .trim(from: 0, to: 0.22)
                        .stroke(.primary.opacity(0.6), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .frame(width: size * 1.9, height: size * 1.9)
                        .phaseAnimator([0.0, 360.0]) { view, angle in
                            view.rotationEffect(.degrees(angle))
                        } animation: { _ in .linear(duration: 0.9).repeatForever(autoreverses: false) }
                        .transition(.opacity)
                }
            }
            .frame(width: size * 2, height: size * 2)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .medium), trigger: playing)
        .accessibilityLabel(playing ? String(localized: "Pause", table: "Player") : String(localized: "Play", table: "Player"))
        .accessibilityValue(player.isBuffering ? String(localized: "Buffering", table: "Player") : "")
    }
}

extension View {
    /// Adds a long-press action to a `Button`. The button still receives the tap when the finger lifts after a
    /// long press, so its action must return early while `didLongPress` is set. The flag is cleared when the next
    /// touch begins – a long press whose release doesn't reach the button can't swallow a later tap.
    func longPressAction(minimumDuration: Double = 0.5, didLongPress: Binding<Bool>, perform action: @escaping () -> Void) -> some View {
        simultaneousGesture(
            LongPressGesture(minimumDuration: minimumDuration)
                .onChanged { _ in
                    didLongPress.wrappedValue = false
                }
                .onEnded { _ in
                    didLongPress.wrappedValue = true
                    action()
                }
        )
    }
}

/// Skip button: taps are combined (`registerSkipTap`), long-press jumps to the chapter start / next chapter.
struct SkipButton: View {
    let forward: Bool
    let size: CGFloat

    @State private var longPressed = false
    @State private var tapTrigger = 0
    @State private var chapterTrigger = 0

    private var player: AudioPlayer { .shared }
    private var interval: Int {
        forward ? AppSettings.shared.skipForwardInterval : AppSettings.shared.skipBackwardInterval
    }

    var body: some View {
        Button {
            if longPressed {
                longPressed = false
                return
            }
            tapTrigger += 1
            player.registerSkipTap(forward: forward)
            Task { await SkipLongPressTip.skipTapped.donate() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: size * 2, height: size * 2)
                .contentShape(.circle)
                .symbolEffect(.bounce.byLayer, value: tapTrigger)
        }
        .buttonStyle(.plain)
        .longPressAction(didLongPress: $longPressed) {
            chapterTrigger += 1
            PlayerTips.skipLongPress.invalidate(reason: .actionPerformed)
            Task {
                if forward {
                    await player.nextChapter()
                } else {
                    await player.previousChapter()
                }
            }
        }
        .overlay(alignment: .top) {
            if let total = player.pendingSkipTotal, (total > 0) == forward {
                Text(verbatim: (total > 0 ? "+" : "−") + HearthFormat.clock(abs(total)))
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.hearthTint, in: .capsule)
                    .foregroundStyle(.white)
                    .offset(y: -10)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.snappy, value: player.pendingSkipTotal)
        .sensoryFeedback(.impact(weight: .light), trigger: tapTrigger)
        .sensoryFeedback(.impact(weight: .heavy), trigger: chapterTrigger)
        .accessibilityLabel(forward ? String(localized: "Skip forward \(interval) seconds", table: "Player") : String(localized: "Skip back \(interval) seconds", table: "Player"))
        .accessibilityHint(forward ? String(localized: "Long-press to go to the next chapter", table: "Player") : String(localized: "Long-press to go to the start of the chapter", table: "Player"))
        .accessibilityAction(named: forward ? String(localized: "Next chapter", table: "Player") : String(localized: "Previous chapter", table: "Player")) {
            Task {
                if forward {
                    await player.nextChapter()
                } else {
                    await player.previousChapter()
                }
            }
        }
    }

    private var symbol: String {
        let supported = [5, 10, 15, 30, 45, 60, 75, 90]
        let name = forward ? "goforward" : "gobackward"
        return supported.contains(interval) ? "\(name).\(interval)" : name
    }
}

// MARK: - Speed

/// "1.3×": tap cycles presets, long-press shows presets and fine −/+ steps.
struct SpeedButton: View {
    var font: Font = .headline

    private var player: AudioPlayer { .shared }

    var body: some View {
        Menu {
            Section {
                ForEach(AppSettings.shared.playbackRatePresets, id: \.self) { rate in
                    Button {
                        player.setPlaybackRate(rate)
                    } label: {
                        if abs(rate - player.playbackRate) < 0.001 {
                            Label(HearthFormat.rate(rate), systemImage: "checkmark")
                        } else {
                            Text(HearthFormat.rate(rate))
                        }
                    }
                }
            } header: {
                Text("Playback Speed", tableName: "Player")
            }
            ControlGroup {
                Button {
                    player.stepPlaybackRate(up: false)
                } label: {
                    Label(String(localized: "Slower", table: "Player"), systemImage: "minus")
                }
                Button {
                    player.stepPlaybackRate(up: true)
                } label: {
                    Label(String(localized: "Faster", table: "Player"), systemImage: "plus")
                }
            }
        } label: {
            Text(HearthFormat.rate(player.playbackRate))
                .font(font.monospacedDigit())
                .contentTransition(.numericText(value: player.playbackRate))
                .frame(minWidth: 44, minHeight: 44)
        } primaryAction: {
            player.cyclePlaybackRate()
        }
        .menuActionDismissBehavior(.disabled)
        .sensoryFeedback(.selection, trigger: player.playbackRate)
        .accessibilityLabel(String(localized: "Playback speed", table: "Player"))
        .accessibilityValue(HearthFormat.rate(player.playbackRate))
        .accessibilityHint(String(localized: "Tap to cycle speeds, touch and hold for more options", table: "Player"))
    }
}

// MARK: - Sleep timer

struct SleepTimerButton: View {
    var font: Font = .title3

    private var player: AudioPlayer { .shared }

    var body: some View {
        Menu {
            if let timer = player.sleepTimer {
                Section {
                    ControlGroup {
                        Button {
                            player.adjustSleepTimer(by: -1)
                        } label: {
                            Label(timer.isChapterBased ? String(localized: "One Chapter Less", table: "Player") : String(localized: "One Minute Less", table: "Player"), systemImage: "minus")
                        }
                        Button {
                            player.adjustSleepTimer(by: 1)
                        } label: {
                            Label(timer.isChapterBased ? String(localized: "One Chapter More", table: "Player") : String(localized: "One Minute More", table: "Player"), systemImage: "plus")
                        }
                    }
                    Button {
                        player.extendSleepTimer()
                    } label: {
                        Label(String(localized: "Extend", table: "Player"), systemImage: "goforward.plus")
                    }
                    Button(role: .destructive) {
                        player.cancelSleepTimer()
                    } label: {
                        Label(String(localized: "Turn Off Sleep Timer", table: "Player"), systemImage: "moon.zzz")
                    }
                } header: {
                    Text(SleepTimerText.status(timer, remaining: player.sleepTimerRemaining))
                }
            } else {
                Section {
                    if player.chapters.count > 1 {
                        Button {
                            player.setSleepTimer(.endOfChapter)
                        } label: {
                            Label(String(localized: "End of Chapter", table: "Player"), systemImage: "book.pages")
                        }
                    }
                    ForEach(AppSettings.shared.sleepTimerPresets.sorted(by: >), id: \.self) { minutes in
                        Button {
                            player.setSleepTimer(.minutes(minutes))
                        } label: {
                            Text(SleepTimerText.minutes(minutes))
                        }
                    }
                } header: {
                    Text("Sleep Timer", tableName: "Player")
                }
            }
        } label: {
            label
                .frame(minWidth: 44, minHeight: 44)
        }
        .menuOrder(.fixed)
        .sensoryFeedback(.success, trigger: player.sleepTimer != nil)
        .accessibilityLabel(String(localized: "Sleep timer", table: "Player"))
        .accessibilityValue(player.sleepTimer.map { SleepTimerText.status($0, remaining: player.sleepTimerRemaining) } ?? String(localized: "Off", table: "Player"))
    }

    @ViewBuilder
    private var label: some View {
        if let timer = player.sleepTimer {
            HStack(spacing: 4) {
                Image(systemName: "moon.zzz.fill")
                Text(SleepTimerText.short(timer, remaining: player.sleepTimerRemaining))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.hearthTint)
        } else {
            Image(systemName: "moon.zzz")
                .font(font)
        }
    }
}

enum SleepTimerText {
    static func minutes(_ minutes: Int) -> String {
        Duration.seconds(Double(minutes) * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide))
    }

    /// "12:34" or "2 ch."
    static func short(_ timer: SleepTimerState, remaining: TimeInterval?) -> String {
        switch timer {
        case .duration:
            return HearthFormat.clock(remaining ?? 0)
        case .chapters(let count, _):
            return String(localized: "\(count) ch.", table: "Player")
        }
    }

    /// "Stops in 12:34" / "Stops at the end of the chapter" / "Stops after 3 chapters".
    static func status(_ timer: SleepTimerState, remaining: TimeInterval?) -> String {
        switch timer {
        case .duration:
            String(localized: "Stops in \(HearthFormat.clock(remaining ?? 0))", table: "Player")
        case .chapters(let count, _):
            count <= 1 ? String(localized: "Stops at the end of the chapter", table: "Player") : String(localized: "Stops after \(count) chapters", table: "Player")
        }
    }
}

// MARK: - Tips

enum PlayerTips {
    static let skipLongPress = SkipLongPressTip()
    static let bookmarkLongPress = BookmarkLongPressTip()
    static let upNext = UpNextConfigurationTip()

    @MainActor private static var configured = false

    /// Configures TipKit once per process (no-op if another part of the app already did).
    @MainActor
    static func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        try? Tips.configure([.displayFrequency(.daily)])
    }
}

struct SkipLongPressTip: Tip {
    /// Donated on every skip tap; the tip appears once the user skipped a few times.
    static let skipTapped = Tips.Event(id: "skipTapped")

    var rules: [Rule] {
        #Rule(Self.skipTapped) { $0.donations.count >= 4 }
    }

    var title: Text { Text("Jump Between Chapters", tableName: "Player") }
    var message: Text? { Text("Touch and hold the skip buttons to go to the start of the chapter or the next chapter.", tableName: "Player") }
    var image: Image? { Image(systemName: "hand.tap") }
    var options: [any TipOption] { [Tips.MaxDisplayCount(2)] }
}

struct BookmarkLongPressTip: Tip {
    /// Donated when a bookmark is created through the note prompt.
    static let notePromptUsed = Tips.Event(id: "bookmarkNotePromptUsed")

    var rules: [Rule] {
        #Rule(Self.notePromptUsed) { $0.donations.count >= 2 }
    }

    var title: Text { Text("Quick Bookmarks", tableName: "Player") }
    var message: Text? { Text("Touch and hold the bookmark button to save a bookmark without a note.", tableName: "Player") }
    var image: Image? { Image(systemName: "bookmark") }
    var options: [any TipOption] { [Tips.MaxDisplayCount(2)] }
}

struct UpNextConfigurationTip: Tip {
    var title: Text { Text("Configure Up Next", tableName: "Player") }
    var message: Text? { Text("Choose what plays next in the settings of a series or podcast.", tableName: "Player") }
    var image: Image? { Image(systemName: "text.line.first.and.arrowtriangle.forward") }
}
