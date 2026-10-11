import HearthData
import HearthModel
import HearthPlayback
import HearthUI
import SwiftUI
import WatchKit

/// Custom player for local (watch) and remote (iPhone) playback.
///
/// Layout: title block + volume (Digital Crown), chapter progress, transport, bottom toolbar
/// (speed, sleep timer, more).
struct NowPlayingScreen: View {
    private var player: WatchPlayer { .shared }

    var body: some View {
        Group {
            if player.isActive {
                content
            } else {
                ContentUnavailableView("Nothing Playing", systemImage: "headphones", description: Text("Start an audiobook or episode on your watch or iPhone."))
            }
        }
        .containerBackground(for: .navigation) {
            NowPlayingBackground(id: player.itemID)
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private var content: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 6) {
                titleBlock
                ChapterProgress(date: context.date)
                Spacer(minLength: 0)
                TransportControls()
                if let error = AudioPlayer.shared.lastError, player.mode == .local, !player.isPlaying {
                    Text(error.localizedDescription)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if player.mode == .phone {
                    Image(systemName: "iphone")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Controlling iPhone")
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                NavigationLink(value: WatchRoute.playbackSpeed) {
                    Text(HearthFormat.rate(player.playbackRate))
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.white)
                }
                .accessibilityLabel("Playback Speed")

                NavigationLink(value: WatchRoute.sleepTimer) {
                    Image(systemName: player.sleepTimer == nil ? "moon.zzz" : "moon.zzz.fill")
                        .foregroundStyle(Color.white)
                }
                .accessibilityLabel("Sleep Timer")

                NavigationLink(value: WatchRoute.playerOptions) {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(Color.white)
                }
                .accessibilityLabel("More")
            }
        }
    }

    private var titleBlock: some View {
        HStack(alignment: .top, spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                Text(player.chapterTitle ?? player.title)
                    .font(.headline)
                    .lineLimit(2)
                    .contentTransition(.opacity)
                Text(player.chapterTitle == nil ? (player.subtitle ?? "") : player.title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            VolumeControl(origin: player.mode == .phone ? .companion : .local)
                .frame(width: 30, height: 30)
                .accessibilityLabel("Volume")
        }
    }
}

/// Blurred cover behind the player.
private struct NowPlayingBackground: View {
    let id: ItemIdentifier?

    var body: some View {
        ZStack {
            Color.black
            if let id {
                ItemImage(id: id, size: .small, cornerRadius: 0)
                    .scaledToFill()
                    .blur(radius: 24)
                    .opacity(0.55)
            }
            LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}

/// Chapter-relative progress bar with elapsed / remaining labels.
private struct ChapterProgress: View {
    let date: Date
    private var player: WatchPlayer { .shared }

    var body: some View {
        let elapsed = player.displayedTime(at: date)
        let total = player.displayedDuration
        let remaining = max(0, total - elapsed) / max(player.playbackRate, 0.01)
        VStack(spacing: 2) {
            ProgressCapsule(progress: total > 0 ? elapsed / total : 0, height: 4)
            HStack {
                Text(HearthFormat.clock(elapsed))
                Spacer()
                if let sleep = player.sleepTimerRemaining(at: date) {
                    Label(HearthFormat.clock(sleep), systemImage: "moon.fill")
                        .foregroundStyle(.tint)
                        .labelStyle(.titleAndIcon)
                } else if player.sleepTimer?.isChapterBased == true {
                    Image(systemName: "moon.fill")
                        .foregroundStyle(.tint)
                }
                Spacer()
                Text(verbatim: "-\(HearthFormat.clock(remaining))")
            }
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Chapter progress")
        .accessibilityValue(Text("\(HearthFormat.clock(elapsed)) of \(HearthFormat.clock(total))"))
    }
}

/// Skip back, play/pause, skip forward. Long press on the skip buttons jumps chapters.
private struct TransportControls: View {
    private var player: WatchPlayer { .shared }

    var body: some View {
        HStack(spacing: 0) {
            SkipButton(symbol: Self.symbol("gobackward", seconds: player.skipBackwardInterval)) {
                await player.skipBackward()
            } longPress: {
                await player.previousChapter()
            }
            .accessibilityLabel("Skip back \(player.skipBackwardInterval) seconds")

            Button {
                Task { await player.togglePlayPause() }
            } label: {
                ZStack {
                    Circle()
                        .fill(.tint.opacity(0.25))
                    if player.isBuffering, !player.isPlaying {
                        ProgressView()
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 54, height: 54)
            }
            .buttonStyle(.plain)
            .handGestureShortcut(.primaryAction)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            SkipButton(symbol: Self.symbol("goforward", seconds: player.skipForwardInterval)) {
                await player.skipForward()
            } longPress: {
                await player.nextChapter()
            }
            .accessibilityLabel("Skip forward \(player.skipForwardInterval) seconds")
        }
    }

    /// Tap skips, long press jumps chapters. Releasing a long press also triggers the button, so its tap is
    /// ignored; the flag resets when the next touch begins so it can't swallow a later tap.
    private struct SkipButton: View {
        let symbol: String
        let tap: @MainActor () async -> Void
        let longPress: @MainActor () async -> Void

        @State private var didLongPress = false

        var body: some View {
            Button {
                if didLongPress {
                    didLongPress = false
                    return
                }
                Task { await tap() }
            } label: {
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                LongPressGesture()
                    .onChanged { _ in
                        didLongPress = false
                    }
                    .onEnded { _ in
                        didLongPress = true
                        Task { await longPress() }
                    }
            )
        }
    }

    /// `gobackward.15` exists for common intervals; fall back to the plain symbol otherwise.
    static func symbol(_ base: String, seconds: Int) -> String {
        [5, 10, 15, 30, 45, 60, 75, 90].contains(seconds) ? "\(base).\(seconds)" : base
    }
}

/// `WKInterfaceVolumeControl`: the Digital Crown changes the watch (local) or iPhone (companion) volume.
struct VolumeControl: WKInterfaceObjectRepresentable {
    let origin: WKInterfaceVolumeControl.Origin

    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        let control = WKInterfaceVolumeControl(origin: origin)
        control.setTintColor(UIColor(AppSettings.shared.tintColor.color))
        control.focus()
        return control
    }

    func updateWKInterfaceObject(_ control: WKInterfaceVolumeControl, context: Context) {}
}
