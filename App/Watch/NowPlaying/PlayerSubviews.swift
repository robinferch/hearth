import HearthData
import HearthModel
import HearthUI
import SwiftUI
import WatchKit

/// Chapter list: current chapter highlighted, past chapters dimmed; tap seeks, swipe sets the sleep timer.
struct ChaptersView: View {
    private var player: WatchPlayer { .shared }

    var body: some View {
        let current = player.currentChapterIndex
        ScrollViewReader { proxy in
            List {
                ForEach(Array(player.chapters.enumerated()), id: \.element.id) { index, chapter in
                    Button {
                        Task { await player.seek(to: chapter) }
                    } label: {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(chapter.title)
                                    .font(.headline.weight(index == current ? .bold : .regular))
                                    .lineLimit(2)
                                Text(HearthFormat.duration(chapter.end - chapter.start))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if index == current {
                                Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                                    .foregroundStyle(.tint)
                                    .accessibilityLabel("Current chapter")
                            }
                        }
                        .opacity(current.map { index < $0 } == true ? 0.55 : 1)
                    }
                    .id(chapter.id)
                    .swipeActions {
                        Button {
                            Task { await player.sleepAtEnd(of: chapter) }
                        } label: {
                            Label("Sleep at End", systemImage: "moon.zzz")
                        }
                        .tint(.indigo)
                    }
                }
            }
            .onAppear {
                if let current, player.chapters.indices.contains(current) {
                    proxy.scrollTo(player.chapters[current].id, anchor: .center)
                }
            }
        }
        .navigationTitle("Chapters")
    }
}

/// Speed presets plus fine adjustment.
struct PlaybackSpeedView: View {
    @State private var rate = 1.0
    private var player: WatchPlayer { .shared }

    var body: some View {
        List {
            Section {
                HStack {
                    Button {
                        set(rate - 0.05)
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Slower")
                    Text(HearthFormat.rate(rate))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                        .focusable()
                        .digitalCrownRotation($rate, from: 0.5, through: 3.5, by: 0.05, sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
                    Button {
                        set(rate + 0.05)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Faster")
                }
                .listRowBackground(Color.clear)
            }
            Section("Presets") {
                ForEach(player.playbackRatePresets.sorted(), id: \.self) { preset in
                    Button {
                        set(preset)
                    } label: {
                        HStack {
                            Text(HearthFormat.rate(preset))
                            Spacer()
                            if abs(preset - player.playbackRate) < 0.001 {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Speed")
        .onAppear { rate = player.playbackRate }
        .onChange(of: rate) { _, value in
            guard abs(value - player.playbackRate) > 0.001 else { return }
            Task { await player.setPlaybackRate(value) }
        }
    }

    private func set(_ value: Double) {
        rate = min(3.5, max(0.5, (value * 100).rounded() / 100))
    }
}

/// Sleep timer presets, or controls for the active timer.
struct SleepTimerView: View {
    private var player: WatchPlayer { .shared }

    var body: some View {
        List {
            if let timer = player.sleepTimer {
                Section {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .leading) {
                            Text("Sleep Timer")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(description(of: timer, at: context.date))
                                .font(.title3.weight(.semibold))
                                .monospacedDigit()
                        }
                    }
                    .listRowBackground(Color.clear)
                    HStack {
                        Button {
                            Task { await player.adjustSleepTimer(by: -1) }
                        } label: {
                            Image(systemName: "minus")
                        }
                        .accessibilityLabel(timer.isChapterBased ? "One chapter less" : "One minute less")
                        Button {
                            Task { await player.adjustSleepTimer(by: 1) }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel(timer.isChapterBased ? "One chapter more" : "One minute more")
                    }
                    .buttonStyle(.bordered)
                    Button("Extend") {
                        Task { await player.extendSleepTimer() }
                    }
                    Button("Cancel Timer", role: .destructive) {
                        Task { await player.cancelSleepTimer() }
                    }
                }
            } else {
                Section {
                    if !player.chapters.isEmpty {
                        Button {
                            Task { await set(.endOfChapter) }
                        } label: {
                            Label("End of Chapter", systemImage: "text.badge.checkmark")
                        }
                    }
                    ForEach(AppSettings.shared.sleepTimerPresets, id: \.self) { minutes in
                        Button {
                            Task { await set(.minutes(minutes)) }
                        } label: {
                            Text(Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide)))
                        }
                    }
                }
            }
        }
        .navigationTitle("Sleep Timer")
    }

    private func set(_ preset: SleepTimerPreset) async {
        await player.setSleepTimer(preset)
        WKInterfaceDevice.current().play(.success)
    }

    private func description(of timer: SleepTimerState, at date: Date) -> String {
        switch timer {
        case .chapters(let remaining, _):
            remaining <= 1 ? String(localized: "End of chapter") : String(localized: "\(remaining) chapters")
        case .duration:
            HearthFormat.clock(player.sleepTimerRemaining(at: date) ?? 0)
        }
    }
}

/// Scrubbing within the current chapter with the Digital Crown.
struct ScrubView: View {
    @State private var position = 0.0
    @State private var didInitialize = false
    @Environment(\.dismiss) private var dismiss

    private var player: WatchPlayer { .shared }

    var body: some View {
        let total = max(player.displayedDuration, 1)
        VStack(spacing: 8) {
            Text(player.chapterTitle ?? player.title)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(HearthFormat.clock(position))
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .focusable()
                .digitalCrownRotation($position, from: 0, through: total, by: 1, sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
            ProgressCapsule(progress: position / total, height: 5)
            Text("Turn the Digital Crown")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("Go") {
                Task {
                    await player.seek(toDisplayedTime: position)
                    dismiss()
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .scenePadding(.horizontal)
        .navigationTitle("Position")
        .onAppear {
            guard !didInitialize else { return }
            didInitialize = true
            position = player.displayedTime(at: .now)
        }
    }
}

/// Secondary player actions: chapters, bookmark, position, audio output, details, stop.
struct PlayerOptionsView: View {
    @State private var showsSystemPlayer = false
    @State private var bookmarkResult: Bool?
    @Environment(\.dismiss) private var dismiss

    private var player: WatchPlayer { .shared }

    var body: some View {
        List {
            if !player.chapters.isEmpty {
                NavigationLink(value: WatchRoute.chapters) {
                    Label("Chapters", systemImage: "list.bullet")
                }
            }
            if player.canCreateBookmark {
                Button {
                    Task { bookmarkResult = await player.createBookmark() }
                } label: {
                    if let bookmarkResult {
                        Label(bookmarkResult ? "Bookmark Added" : "Bookmark Failed", systemImage: bookmarkResult ? "bookmark.fill" : "exclamationmark.triangle")
                    } else {
                        Label("Add Bookmark", systemImage: "bookmark")
                    }
                }
            }
            NavigationLink(value: WatchRoute.scrub) {
                Label("Change Position", systemImage: "slider.horizontal.below.rectangle")
            }
            Button {
                showsSystemPlayer = true
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Label("Audio Output", systemImage: player.routeSymbol)
                    if let route = player.routeName {
                        Text(route)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let id = player.itemID {
                NavigationLink(value: WatchRoute.item(id)) {
                    Label("Show Details", systemImage: "info.circle")
                }
            }
            Button(role: .destructive) {
                Task {
                    await player.stop()
                    dismiss()
                }
            } label: {
                Label("Stop Playback", systemImage: "stop.fill")
            }
        }
        .navigationTitle("Options")
        .sheet(isPresented: $showsSystemPlayer) {
            // The system player offers the route picker (AirPlay / Bluetooth) and system volume.
            NowPlayingView()
        }
    }
}
