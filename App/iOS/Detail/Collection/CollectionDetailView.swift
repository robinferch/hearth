import HearthAPI
import HearthData
import HearthModel
import HearthPlayback
import HearthUI
import SwiftUI

/// Collection or playlist page (`id.kind` is `.collection` or `.playlist`): description, play first unfinished,
/// items, edit sheet and management menu.
struct CollectionDetailView: View {
    let id: ItemIdentifier

    @State private var loader: DetailLoader<ItemCollection>

    init(id: ItemIdentifier) {
        self.id = id
        _loader = State(initialValue: DetailLoader {
            guard case .collection(let collection) = try await HearthData.shared.items.item(id) else {
                throw APIError.notFound
            }
            return collection
        })
    }

    var body: some View {
        LoadStateView(loader.state, retry: { await loader.reload() }) { collection in
            CollectionDetailContent(collection: collection) {
                HearthData.shared.items.invalidate(id)
                await loader.reload()
            }
        }
        .itemUserActivity(id, title: loader.value?.name)
        .task {
            if loader.value == nil {
                await loader.reload()
            }
        }
    }
}

private struct CollectionDetailContent: View {
    let collection: ItemCollection
    let refresh: @MainActor () async -> Void

    @Environment(\.itemActionHandler) private var handler
    @Environment(\.dismiss) private var dismiss
    @Environment(AlertCenter.self) private var alerts
    @Environment(PlayerPresentation.self) private var presentation
    @Environment(Navigator.self) private var navigator

    @State private var isEditing = false
    @State private var isConfiguring = false
    @State private var confirmsDeletion = false
    @State private var dominantColor: HearthRGBColor?

    private var kindName: String { collection.id.kind.localizedName }

    private var firstUnfinished: AnyPlayableItem? {
        collection.items.first { !HearthData.shared.progress.isFinished($0.id) } ?? collection.items.first
    }

    var body: some View {
        List {
            header
                .detailPlainRow(insets: EdgeInsets(top: 0, leading: 20, bottom: 16, trailing: 20))

            Section {
                Group {
                    DetailSectionTitle(title: HearthFormat.itemCount(collection.items.count))
                }
                .detailPlainRow(insets: EdgeInsets(top: 18, leading: 20, bottom: 6, trailing: 20))
                if collection.items.isEmpty {
                    Text("No items yet.", tableName: "Detail")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(collection.items) { item in
                    NavigationLink(value: NavigationDestination.item(item.id)) {
                        switch item {
                        case .audiobook(let book):
                            AudiobookRow(audiobook: book)
                        case .episode(let episode):
                            EpisodeRow(episode: episode, showsCover: true, descriptionLines: 2)
                        }
                    }
                    .itemActions(for: item)
                }
            }
        }
        .listStyle(.plain)
        .heroBackground(color: dominantColor, height: 520)
        .detailNavigationTitle(collection.name, threshold: 300)
        .environment(\.itemActionHandler, handler.withPlaybackOrigin(.collection(collection.id), alerts: alerts, presentation: presentation))
        .refreshable { await refresh() }
        .task(id: collection.items.first?.id) {
            guard let first = collection.items.first?.id else { return }
            let color = await HearthData.shared.images.dominantColor(for: first)
            withAnimation(.smooth) { dominantColor = color }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isEditing = true
                } label: {
                    Text("Edit", tableName: "Detail")
                }
                .disabled(HearthData.shared.connections.isOffline)
                menu
            }
        }
        .sheet(isPresented: $isEditing) {
            CollectionEditSheet(collection: collection) {
                await refresh()
            }
        }
        .sheet(isPresented: $isConfiguring) {
            ConfigureSheet(id: collection.id, title: collection.name)
        }
        .confirmationDialog(String(localized: "Delete “\(collection.name)”?", table: "Detail"), isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button(String(localized: "Delete", table: "Detail"), role: .destructive) {
                Task { await delete() }
            }
        } message: {
            Text("The items themselves stay in your library.", tableName: "Detail")
        }
    }

    private var menu: some View {
        Menu {
            Section {
                Button {
                    Task { await DetailPlayback.playGrouping(collection.id, alerts: alerts, presentation: presentation) }
                } label: {
                    Label(String(localized: "Play", table: "Detail"), systemImage: "play.fill")
                }
                .disabled(collection.items.isEmpty)
                Button {
                    Task {
                        await AudioPlayer.shared.addToQueue(collection.items.map(\.id))
                        alerts.succeed()
                    }
                } label: {
                    Label(String(localized: "Add All to Queue", table: "Detail"), systemImage: "text.line.last.and.arrowtriangle.forward")
                }
                .disabled(collection.items.isEmpty)
            }
            Section {
                if let url = handler.shareURL(collection.id) {
                    ShareLink(item: url) {
                        Label(String(localized: "Share", table: "Detail"), systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    isConfiguring = true
                } label: {
                    Label(String(localized: "Configure", table: "Detail"), systemImage: "slider.horizontal.3")
                }
                if !collection.isPlaylist {
                    Button {
                        Task { await createPlaylist() }
                    } label: {
                        Label(String(localized: "Create Playlist from Collection", table: "Detail"), systemImage: "music.note.list")
                    }
                }
            }
            Section {
                Button(role: .destructive) {
                    confirmsDeletion = true
                } label: {
                    Label(String(localized: "Delete \(kindName)", table: "Detail"), systemImage: "trash")
                }
            }
        } label: {
            Label(String(localized: "More", table: "Detail"), systemImage: "ellipsis")
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            CoverMosaic(ids: collection.items.map(\.id), fallback: collection.id, cornerRadius: 16)
                .frame(width: 190, height: 190)
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                .padding(.top, 12)
            VStack(spacing: 4) {
                Text(kindName)
                    .font(.caption.smallCaps().weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(collection.name)
                    .hearthTitle(.title)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(HearthFormat.joined([HearthFormat.itemCount(collection.items.count), HearthFormat.duration(collection.items.reduce(0) { $0 + $1.duration })]))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let first = firstUnfinished {
                PlayButton(item: first, style: .large, tint: dominantColor)
                    .frame(maxWidth: 380)
                    .padding(.top, 4)
            }
            if collection.descriptionHTML?.isEmpty == false {
                DescriptionView(html: collection.descriptionHTML, collapsedLines: 4, expansion: .sheet(title: collection.name))
                    .frame(maxWidth: 640)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func createPlaylist() async {
        do {
            let id = try await Client.for(collection.id.connectionID).createPlaylist(fromCollection: collection.id)
            alerts.succeed()
            navigator.push(.item(id))
        } catch {
            alerts.fail(error)
        }
    }

    private func delete() async {
        do {
            try await Client.for(collection.id.connectionID).deleteCollection(collection.id)
            HearthData.shared.items.invalidate(collection.id)
            alerts.succeed()
            dismiss()
        } catch {
            alerts.fail(error)
        }
    }
}

// MARK: - Edit

/// Rename, edit the description, reorder and remove items.
struct CollectionEditSheet: View {
    let collection: ItemCollection
    let saved: @MainActor () async -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AlertCenter.self) private var alerts

    @State private var name: String
    @State private var description: String
    @State private var items: [AnyPlayableItem]
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(collection: ItemCollection, saved: @escaping @MainActor () async -> Void) {
        self.collection = collection
        self.saved = saved
        _name = State(initialValue: collection.name)
        _description = State(initialValue: HearthFormat.plainText(fromHTML: collection.descriptionHTML) ?? "")
        _items = State(initialValue: collection.items)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField(String(localized: "Name", table: "Detail"), text: $name)
                    TextField(String(localized: "Description", table: "Detail"), text: $description, axis: .vertical)
                        .lineLimit(2...8)
                }
                Section {
                    ForEach(items) { item in
                        CompactItemRow(item: item, coverSize: 44, showsStatus: false)
                    }
                    .onMove { source, destination in
                        items.move(fromOffsets: source, toOffset: destination)
                    }
                    .onDelete { offsets in
                        items.remove(atOffsets: offsets)
                    }
                } header: {
                    Text(HearthFormat.itemCount(items.count))
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(String(localized: "Edit \(collection.id.kind.localizedName)", table: "Detail"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(role: .confirm) {
                            Task { await save() }
                        }
                        .disabled(trimmedName.isEmpty)
                    }
                }
            }
            .interactiveDismissDisabled(isSaving)
            .alert(String(localized: "Couldn’t Save Changes", table: "Detail"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button(String(localized: "OK", table: "Detail"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let client = try Client.for(collection.id.connectionID)
            let remaining = Set(items.map(\.id))
            let removed = collection.items.map(\.id).filter { !remaining.contains($0) }
            if !removed.isEmpty {
                try await client.removeFromCollection(collection.id, items: removed)
            }
            let originalDescription = HearthFormat.plainText(fromHTML: collection.descriptionHTML) ?? ""
            let orderChanged = items.map(\.id) != collection.items.map(\.id).filter(remaining.contains)
            let nameChanged = trimmedName != collection.name
            let descriptionChanged = description != originalDescription
            if nameChanged || descriptionChanged || orderChanged {
                try await client.updateCollection(
                    collection.id,
                    name: nameChanged ? trimmedName : nil,
                    description: descriptionChanged ? description : nil,
                    items: orderChanged ? items.map(\.id) : nil
                )
            }
            HearthData.shared.items.invalidate(collection.id)
            alerts.succeed()
            await saved()
            dismiss()
        } catch {
            errorMessage = error.userMessage
        }
    }
}
