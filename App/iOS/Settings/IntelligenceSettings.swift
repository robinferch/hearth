import HearthData
import HearthIntelligence
import HearthModel
import HearthUI
import SwiftUI

/// Transcripts & ads: skipping, detection method, storage.
struct IntelligenceSettingsView: View {
    @State private var storageUsed: Int64?
    @State private var confirmsDelete = false

    private var store: TranscriptStore { HearthData.shared.transcripts }

    var body: some View {
        @Bindable var settings = AppSettings.shared
        Form {
            Section {
                Toggle(String(localized: "Skip Ads Automatically", table: "Intelligence"), isOn: $settings.skipAdsAutomatically)
                Toggle(String(localized: "Find Ads When Transcribing", table: "Intelligence"), isOn: $settings.detectAdsAfterTranscription)
            } footer: {
                Text("Detected ads are skipped once while playing; seek back into an ad to hear it. With automatic skipping off, a Skip Ad button appears instead.", tableName: "Intelligence")
            }

            Section {
                LabeledContent(String(localized: "Ad Detection", table: "Intelligence")) {
                    Text(methodTitle)
                }
            } footer: {
                Text(methodFooter)
            }

            Section {
                LabeledContent(String(localized: "Transcripts", table: "Intelligence")) {
                    Text("\(store.entries.count)")
                }
                LabeledContent(String(localized: "Storage", table: "Intelligence")) {
                    if let storageUsed {
                        Text(HearthFormat.bytes(storageUsed))
                    } else {
                        ProgressView()
                    }
                }
                Button(String(localized: "Delete All Transcripts", table: "Intelligence"), role: .destructive) {
                    confirmsDelete = true
                }
                .disabled(store.entries.isEmpty)
            } footer: {
                Text("Transcription and ad detection run entirely on this device. Nothing is uploaded.", tableName: "Intelligence")
            }
        }
        .navigationTitle(String(localized: "Transcripts & Ads", table: "Intelligence"))
        .confirmationDialog(String(localized: "Delete all transcripts?", table: "Intelligence"), isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button(String(localized: "Delete All Transcripts", table: "Intelligence"), role: .destructive) {
                store.removeAll()
                Task { storageUsed = await store.storageUsed() }
            }
        } message: {
            Text("Detected ads are deleted as well.", tableName: "Intelligence")
        }
        .task {
            storageUsed = await store.storageUsed()
        }
    }

    private var methodTitle: String {
        LanguageModelStatus.current == .available
            ? String(localized: "Apple Intelligence", table: "Intelligence")
            : String(localized: "Keywords", table: "Intelligence")
    }

    private var methodFooter: String {
        switch LanguageModelStatus.current {
        case .available:
            String(localized: "Apple Intelligence reads the transcript and finds sponsor reads, commercials and promo codes.", table: "Intelligence")
        case .notEnabled:
            String(localized: "Turn on Apple Intelligence in the Settings app for more accurate ad detection. Until then, ads are found by typical phrases.", table: "Intelligence")
        case .modelNotReady:
            String(localized: "Apple Intelligence is still being set up. Until then, ads are found by typical phrases.", table: "Intelligence")
        case .deviceNotEligible, .unavailable:
            String(localized: "This device doesn't support Apple Intelligence, so ads are found by typical phrases like promo codes and sponsor mentions.", table: "Intelligence")
        }
    }
}
