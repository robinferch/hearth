import HearthData
import HearthModel
import HearthUI
import SwiftUI

struct SleepTimerSettingsView: View {
    @State private var isAddingPreset = false

    var body: some View {
        @Bindable var settings = AppSettings.shared
        Form {
            Section {
                ForEach(settings.sleepTimerPresets, id: \.self) { minutes in
                    Text(Self.format(minutes: minutes))
                        .monospacedDigit()
                }
                .onDelete { offsets in
                    guard settings.sleepTimerPresets.count - offsets.count >= 1 else { return }
                    settings.sleepTimerPresets.remove(atOffsets: offsets)
                }
                Button {
                    isAddingPreset = true
                } label: {
                    Label("Add Preset", systemImage: "plus")
                }
            } header: {
                Text("Presets")
            } footer: {
                Text("Shown in the player's sleep timer menu, together with “End of Chapter”.")
            }

            Section {
                Toggle("Extend by Previous Duration", isOn: $settings.sleepTimerExtendByPrevious)
                if !settings.sleepTimerExtendByPrevious {
                    Stepper(value: $settings.sleepTimerExtendMinutes, in: 1...180) {
                        LabeledContent("Extend by", value: String(localized: "\(settings.sleepTimerExtendMinutes) min"))
                    }
                }
                Stepper(value: $settings.sleepTimerExtendChapters, in: 1...42) {
                    LabeledContent("Extend Chapter Timer by", value: String(localized: "\(settings.sleepTimerExtendChapters) chapters"))
                }
            } header: {
                Text("Extending")
            } footer: {
                Text("When on, “Extend” adds the timer's original duration again.")
            }

            Section {
                Toggle("Fade Out", isOn: $settings.sleepTimerFadeOut)
                Toggle("Shake to Extend", isOn: $settings.shakeExtendsSleepTimer)
                Toggle("Play to Extend", isOn: $settings.playExtendsSleepTimer)
            } footer: {
                Text("Fade out lowers the volume during the last 10 seconds. Play to extend restarts the timer when you resume within 10 seconds after it ended.")
            }

            Section {
                Button("Reset Sleep Timer Settings", role: .destructive) {
                    settings.resetSleepTimer()
                }
            }
        }
        .navigationTitle("Sleep Timer")
        .toolbar {
            EditButton()
        }
        .sheet(isPresented: $isAddingPreset) {
            SleepTimerPresetPicker { minutes in
                guard minutes > 0, !settings.sleepTimerPresets.contains(minutes) else { return }
                settings.sleepTimerPresets = (settings.sleepTimerPresets + [minutes]).sorted()
            }
            .presentationDetents([.height(360)])
        }
    }

    static func format(minutes: Int) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide))
    }
}

/// H:MM wheel picker for a new sleep timer preset.
struct SleepTimerPresetPicker: View {
    let onAdd: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var hours = 0
    @State private var minutes = 30

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                Picker("Hours", selection: $hours) {
                    ForEach(0..<10, id: \.self) { value in
                        Text("\(value) h").tag(value)
                    }
                }
                .pickerStyle(.wheel)
                Picker("Minutes", selection: $minutes) {
                    ForEach(0..<60, id: \.self) { value in
                        Text("\(value) min").tag(value)
                    }
                }
                .pickerStyle(.wheel)
            }
            .padding(.horizontal)
            .navigationTitle("New Preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", systemImage: "checkmark") {
                        onAdd(hours * 60 + minutes)
                        dismiss()
                    }
                    .disabled(hours == 0 && minutes == 0)
                }
            }
        }
    }
}
