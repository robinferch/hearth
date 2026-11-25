import HearthData
import HearthIntelligence
import HearthModel
import HearthUI
import SwiftUI

/// Transcripts & ads: skipping, who finds the ads (Apple Intelligence, a model on the device, Claude, keywords),
/// storage.
struct IntelligenceSettingsView: View {
    @State private var storageUsed: Int64?
    @State private var confirmsDelete = false

    private var store: TranscriptStore { HearthData.shared.transcripts }

    var body: some View {
        @Bindable var settings = AppSettings.shared
        let provider = AdDetectionProvider(setting: settings.adDetectionProvider)
        Form {
            Section {
                Toggle(String(localized: "Skip Ads Automatically", table: "Intelligence"), isOn: $settings.skipAdsAutomatically)
                Toggle(String(localized: "Find Ads When Transcribing", table: "Intelligence"), isOn: $settings.detectAdsAfterTranscription)
            } footer: {
                Text("Detected ads are skipped once while playing; seek back into an ad to hear it. With automatic skipping off, a Skip Ad button appears instead.", tableName: "Intelligence")
            }

            Section {
                Picker(String(localized: "Find Ads With", table: "Intelligence"), selection: Binding(
                    get: { provider.rawValue },
                    set: { settings.adDetectionProvider = $0 }
                )) {
                    ForEach(AdDetectionProvider.selectable) { option in
                        Text(Self.title(of: option)).tag(option.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Ad Detection", tableName: "Intelligence")
            } footer: {
                Text(footer(for: provider))
            }

            switch provider {
            case .localModel:
                LocalModelsSection()
            case .anthropic:
                AnthropicSection()
            default:
                EmptyView()
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
                Text("Transcription always runs on this device. Only with Claude is the transcript sent to Anthropic to find ads.", tableName: "Intelligence")
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

    static func title(of provider: AdDetectionProvider) -> String {
        switch provider {
        case .automatic: String(localized: "Automatic", table: "Intelligence")
        case .appleIntelligence: String(localized: "Apple Intelligence", table: "Intelligence")
        case .localModel: String(localized: "Model on This iPhone", table: "Intelligence")
        case .anthropic: String(localized: "Claude (Own API Key)", table: "Intelligence")
        case .keywords: String(localized: "Keywords Only", table: "Intelligence")
        }
    }

    private func footer(for provider: AdDetectionProvider) -> String {
        var text: String = switch provider {
        case .automatic:
            String(localized: "Apple Intelligence where available, otherwise typical phrases like promo codes and sponsor mentions.", table: "Intelligence")
        case .appleIntelligence:
            String(localized: "Apple's on-device model reads the transcript. Very long or sensitive passages (e.g. true crime) may be declined; keywords are used there.", table: "Intelligence")
        case .localModel:
            String(localized: "An open model like Gemma runs entirely on this iPhone, without content restrictions. Needs a one-time download and iOS 27.", table: "Intelligence")
        case .anthropic:
            String(localized: "Claude reads the whole transcript at once and is the most accurate. The transcript (not the audio) is sent to Anthropic and billed to your account.", table: "Intelligence")
        case .keywords:
            String(localized: "Typical phrases like promo codes, sponsor mentions and web addresses. Fast, but misses ads without them.", table: "Intelligence")
        }
        if let reason = AdDetectionPlan.current(for: .current).unavailability {
            text += "\n\n" + AdDetectionText.unavailability(reason)
        }
        return text
    }
}

// MARK: - Models on the device

private struct LocalModelsSection: View {
    @State private var pendingDownload: LocalAdModel?

    private var manager: LocalModelManager { .shared }

    var body: some View {
        @Bindable var settings = AppSettings.shared
        Section {
            if manager.isSupported {
                ForEach(LocalAdModel.all) { model in
                    LocalModelRow(
                        model: model,
                        isSelected: settings.localAdModelID == model.id,
                        status: manager.status(of: model),
                        select: { settings.localAdModelID = model.id },
                        download: {
                            settings.localAdModelID = model.id
                            if HearthData.shared.connections.isExpensiveNetwork {
                                pendingDownload = model
                            } else {
                                manager.download(model)
                            }
                        }
                    )
                }
            } else {
                Text("Models on the iPhone need iOS 27.", tableName: "Intelligence")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Model on This iPhone", tableName: "Intelligence")
        } footer: {
            Text("Gemma 4 E2B is fast and finds most ads. Gemma 4 E4B is more precise but takes about twice as long and needs an iPhone with 12 GB of memory. Keep Hearth open while a model downloads. The model is only loaded while ads are being found.", tableName: "Intelligence")
        }
        .onAppear { manager.refresh() }
        .confirmationDialog(
            String(localized: "Download over cellular?", table: "Intelligence"),
            isPresented: Binding(get: { pendingDownload != nil }, set: { if !$0 { pendingDownload = nil } }),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Download", table: "Intelligence")) {
                if let pendingDownload { manager.download(pendingDownload) }
            }
        } message: {
            if let pendingDownload {
                Text(String(localized: "\(pendingDownload.name) is \(HearthFormat.bytes(pendingDownload.downloadBytes)).", table: "Intelligence"))
            }
        }
    }
}

private struct LocalModelRow: View {
    let model: LocalAdModel
    let isSelected: Bool
    let status: LocalModelManager.Status
    let select: () -> Void
    let download: () -> Void

    @State private var confirmsDelete = false
    private var manager: LocalModelManager { .shared }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: select) {
                HStack(spacing: 12) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(model.name)
                                .foregroundStyle(.primary)
                            if model.isRecommended {
                                Text("Recommended", tableName: "Intelligence")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.18), in: .capsule)
                            }
                        }
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if case .downloading(let fraction) = status {
                            ProgressView(value: fraction)
                        }
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!model.fitsDevice)
            Spacer(minLength: 0)
            actions
        }
        .opacity(model.fitsDevice ? 1 : 0.5)
        .confirmationDialog(String(localized: "Delete \(model.name)?", table: "Intelligence"), isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button(String(localized: "Delete", table: "Intelligence"), role: .destructive) {
                manager.delete(model)
            }
        }
    }

    private var detail: String {
        if !model.fitsDevice {
            return String(localized: "Needs more memory than iOS allows Hearth", table: "Intelligence")
        }
        switch status {
        case .ready: return String(localized: "Downloaded", table: "Intelligence")
        case .downloading(let fraction): return String(localized: "Downloading… \(HearthFormat.percent(fraction))", table: "Intelligence")
        case .failed(let message): return message
        case .notDownloaded: return HearthFormat.bytes(model.downloadBytes)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch status {
        case .downloading:
            Button {
                manager.cancelDownload(model)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Cancel Download", table: "Intelligence"))
        case .ready:
            Button {
                confirmsDelete = true
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Delete", table: "Intelligence"))
        case .notDownloaded, .failed:
            if model.fitsDevice {
                Button(action: download) {
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel(String(localized: "Download", table: "Intelligence"))
            }
        }
    }
}

// MARK: - Claude

private struct AnthropicSection: View {
    @State private var key = ""
    @State private var hasKey = SecretStore.has(.anthropicAPIKey)
    @State private var isChecking = false
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        @Bindable var settings = AppSettings.shared
        Section {
            if hasKey {
                LabeledContent(String(localized: "API Key", table: "Intelligence")) {
                    Label(String(localized: "Saved", table: "Intelligence"), systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
                Button(String(localized: "Remove API Key", table: "Intelligence"), role: .destructive) {
                    SecretStore.set(nil, for: .anthropicAPIKey)
                    hasKey = false
                    message = nil
                }
            } else {
                SecureField(String(localized: "API Key (sk-ant-…)", table: "Intelligence"), text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.password)
                Button {
                    check()
                } label: {
                    HStack {
                        Text("Check and Save", tableName: "Intelligence")
                        if isChecking {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || isChecking)
                Link(String(localized: "Create a Key in the Anthropic Console", table: "Intelligence"), destination: URL(string: "https://console.anthropic.com/settings/keys")!)
            }
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(isError ? .red : .green)
            }
        } header: {
            Text("Claude", tableName: "Intelligence")
        } footer: {
            Text("The key is stored in the Keychain on this device only.", tableName: "Intelligence")
        }

        Section {
            Picker(String(localized: "Model", table: "Intelligence"), selection: $settings.anthropicModel) {
                ForEach(AnthropicModel.all) { model in
                    let cost = model.costPerHour.formatted(.currency(code: "USD").precision(.fractionLength(2 ... 3)))
                    VStack(alignment: .leading) {
                        Text(model.name)
                        Text(String(localized: "about \(cost) per hour of podcast", table: "Intelligence"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(model.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text("Model", tableName: "Intelligence")
        } footer: {
            Text("Prices are Anthropic's list prices and may change. Opus is the most accurate, Haiku the cheapest.", tableName: "Intelligence")
        }
    }

    private func check() {
        let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
        isChecking = true
        message = nil
        Task {
            defer { isChecking = false }
            do {
                try await AnthropicKeyValidator.validate(candidate)
                SecretStore.set(candidate, for: .anthropicAPIKey)
                key = ""
                hasKey = true
                isError = false
                message = String(localized: "The key works.", table: "Intelligence")
            } catch {
                isError = true
                message = error.localizedDescription
            }
        }
    }
}
