import HearthData
import HearthModel
import HearthUI
import SwiftUI

struct PlaybackSettingsView: View {
    var body: some View {
        @Bindable var settings = AppSettings.shared
        Form {
            Section {
                NavigationLink {
                    SpeedPresetsEditor()
                } label: {
                    LabeledContent("Speed Presets", value: settings.playbackRatePresets.map(HearthFormat.rate).joined(separator: " · "))
                }
                Picker("Default Speed", selection: $settings.defaultPlaybackRate) {
                    ForEach(Self.rateOptions(including: settings.defaultPlaybackRate), id: \.self) { rate in
                        Text(HearthFormat.rate(rate)).tag(rate)
                    }
                }
                Picker("Speed Up Step", selection: $settings.playbackRateStepUp) {
                    ForEach(Self.stepOptions, id: \.self) { step in
                        Text(HearthFormat.rate(step)).tag(step)
                    }
                }
                Picker("Slow Down Step", selection: $settings.playbackRateStepDown) {
                    ForEach(Self.stepOptions, id: \.self) { step in
                        Text(HearthFormat.rate(step)).tag(step)
                    }
                }
            } header: {
                Text("Speed")
            } footer: {
                Text("Changes to the speed are remembered for each book and episode.")
            }

            Section("Skip Intervals") {
                Picker(selection: $settings.skipBackwardInterval) {
                    ForEach(AppSettings.skipIntervalOptions, id: \.self) { seconds in
                        Label(Self.seconds(seconds), systemImage: "gobackward.\(seconds)").tag(seconds)
                    }
                } label: {
                    Label("Skip Back", systemImage: "gobackward")
                }
                Picker(selection: $settings.skipForwardInterval) {
                    ForEach(AppSettings.skipIntervalOptions, id: \.self) { seconds in
                        Label(Self.seconds(seconds), systemImage: "goforward.\(seconds)").tag(seconds)
                    }
                } label: {
                    Label("Skip Forward", systemImage: "goforward")
                }
            }

            Section {
                Toggle("Smart Rewind", isOn: $settings.smartRewind)
            } footer: {
                Text("Rewinds a few seconds when you resume after a pause, so you don't lose track.")
            }

            Section {
                Toggle("Chapter Progress", isOn: $settings.chapterRelativeProgress)
                Toggle("Lock Seek Bar", isOn: $settings.lockSeekBar)
                Toggle("Total Progress Instead of Volume", isOn: $settings.replaceVolumeWithTotalProgress)
            } header: {
                Text("Player")
            } footer: {
                Text("Chapter progress shows the position within the current chapter in the player and on the Lock Screen.")
            }

            Section {
                Toggle("Next/Previous Skips Chapters", isOn: $settings.remoteNextPreviousSkipsChapters)
            } footer: {
                Text("Headphone and Lock Screen next/previous buttons jump between chapters instead of skipping.")
            }

            Section {
                Toggle("Generate Up Next", isOn: $settings.generateUpNext)
            } footer: {
                Text("Automatically continues with the next book of a series or the next episode of a podcast.")
            }
        }
        .navigationTitle("Playback")
    }

    static let stepOptions: [Double] = [0.05, 0.1, 0.2, 0.25, 0.5]

    static func rateOptions(including current: Double) -> [Double] {
        var options = stride(from: 0.5, through: 3.0, by: 0.1).map { ($0 * 100).rounded() / 100 }
        if !options.contains(current) {
            options.append(current)
            options.sort()
        }
        return options
    }

    static func seconds(_ value: Int) -> String {
        Duration.seconds(value).formatted(.units(allowed: [.seconds], width: .abbreviated))
    }
}

/// Edit playback speed presets (0.25–4.0 in 0.05 steps, at least one).
struct SpeedPresetsEditor: View {
    @State private var newRate = 1.5

    var body: some View {
        @Bindable var settings = AppSettings.shared
        Form {
            Section {
                ForEach(settings.playbackRatePresets, id: \.self) { rate in
                    Text(HearthFormat.rate(rate))
                        .monospacedDigit()
                }
                .onDelete { offsets in
                    guard settings.playbackRatePresets.count - offsets.count >= 1 else { return }
                    settings.playbackRatePresets.remove(atOffsets: offsets)
                }
            } header: {
                Text("Presets")
            } footer: {
                Text("Tapping the speed button in the player cycles through these presets.")
            }

            Section("Add Preset") {
                Stepper(value: $newRate, in: 0.25...4.0, step: 0.05) {
                    Text(HearthFormat.rate(newRate))
                        .monospacedDigit()
                }
                Button("Add") {
                    let rate = (newRate * 100).rounded() / 100
                    guard !settings.playbackRatePresets.contains(rate) else { return }
                    settings.playbackRatePresets = (settings.playbackRatePresets + [rate]).sorted()
                }
                .disabled(settings.playbackRatePresets.contains((newRate * 100).rounded() / 100))
            }

            Section {
                Button("Reset Speeds", role: .destructive) {
                    settings.resetPlaybackRates()
                }
            }
        }
        .navigationTitle("Speed Presets")
        .toolbar {
            EditButton()
        }
    }
}
