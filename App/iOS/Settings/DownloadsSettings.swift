import HearthData
import HearthModel
import HearthUI
import SwiftUI

struct DownloadsSettingsView: View {
    @State private var storageUsed: Int64?
    @State private var cacheSize: Int64?
    @State private var confirmsRemoveDownloads = false
    @State private var isWorking = false

    private var downloads: DownloadManager { HearthData.shared.downloads }

    var body: some View {
        @Bindable var settings = AppSettings.shared
        Form {
            Section {
                Toggle("Download over Cellular", isOn: $settings.allowCellularDownloads)
                Toggle("Remove Finished Downloads", isOn: $settings.removeFinishedDownloads)
            } footer: {
                Text("Finished books and episodes are removed from your device automatically.")
            }

            Section {
                Toggle("Automatic Downloads", isOn: $settings.autoDownloadsEnabled)
                Toggle("Auto-Download Listen Now", isOn: $settings.autoDownloadListenNow)
                    .disabled(!settings.autoDownloadsEnabled)
            } footer: {
                Text("Hearth checks for new items about every three hours in the background.")
            }

            Section {
                let configurations = downloads.autoDownloadConfigurations()
                if configurations.isEmpty {
                    Text("Set up automatic downloads for a series or podcast from its page.")
                        .foregroundStyle(.secondary)
                }
                ForEach(configurations, id: \.grouping) { configuration in
                    AutoDownloadConfigurationRow(grouping: configuration.grouping, rule: configuration.rule)
                }
            } header: {
                Text("Rules")
            }

            Section {
                LabeledContent("Downloads") {
                    if let storageUsed {
                        Text(HearthFormat.bytes(storageUsed))
                    } else {
                        ProgressView()
                    }
                }
                LabeledContent("Cache") {
                    if let cacheSize {
                        Text(HearthFormat.bytes(cacheSize))
                    } else {
                        ProgressView()
                    }
                }
            } header: {
                Text("Storage")
            }

            Section {
                Button("Clear Cache") {
                    isWorking = true
                    Task {
                        await HearthData.shared.purgeCache()
                        DecodedImageCache.shared.removeAll()
                        await refreshSizes()
                        isWorking = false
                    }
                }
                Button("Remove All Downloads", role: .destructive) {
                    confirmsRemoveDownloads = true
                }
            }
            .disabled(isWorking)
        }
        .navigationTitle("Downloads")
        .task { await refreshSizes() }
        .confirmationDialog("Remove all downloads?", isPresented: $confirmsRemoveDownloads, titleVisibility: .visible) {
            Button("Remove All Downloads", role: .destructive) {
                isWorking = true
                Task {
                    await downloads.removeAll()
                    await refreshSizes()
                    isWorking = false
                }
            }
        } message: {
            Text("Downloaded audiobooks and episodes are deleted from this device. Your progress is kept.")
        }
    }

    private func refreshSizes() async {
        storageUsed = await downloads.storageUsed()
        cacheSize = await HearthData.shared.cacheSize()
    }
}

/// A configured grouping (series / podcast / collection) with an inline rule picker.
private struct AutoDownloadConfigurationRow: View {
    let grouping: ItemIdentifier
    let rule: AutoDownloadRule

    @State private var name: String?

    var body: some View {
        Picker(selection: Binding(
            get: { rule },
            set: { newValue in
                Task { await HearthData.shared.downloads.setAutoDownloadRule(newValue, for: grouping) }
            }
        )) {
            ForEach(AutoDownloadRule.options(forPodcast: grouping.kind == .podcast), id: \.self) { option in
                Text(option.localizedName).tag(option)
            }
        } label: {
            HStack(spacing: 10) {
                ItemImage(id: grouping, size: .tiny, cornerRadius: 5)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name ?? grouping.kind.localizedName)
                        .lineLimit(1)
                    Text(grouping.kind.localizedName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .pickerStyle(.menu)
        .task(id: grouping) {
            name = (try? await HearthData.shared.items.item(grouping))?.name
        }
    }
}
