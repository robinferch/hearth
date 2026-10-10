import HearthData
import HearthModel
import HearthUI
import SwiftUI

/// "Add to…" sheet: collections (audiobooks only) and playlists, each with "New…".
struct AddToSheet: View {
    let itemID: ItemIdentifier

    @Environment(\.dismiss) private var dismiss
    @Environment(AlertCenter.self) private var alerts
    @Environment(Navigator.self) private var navigator

    @State private var collections: LoadState<[ItemCollection]> = .loading
    @State private var playlists: LoadState<[ItemCollection]> = .loading
    @State private var newName = ""
    @State private var creatingPlaylist: Bool?
    @State private var working: ItemIdentifier?

    private var allowsCollections: Bool { itemID.kind == .audiobook }

    var body: some View {
        NavigationStack {
            List {
                if allowsCollections {
                    section(title: String(localized: "Collections"), state: collections, playlist: false)
                }
                section(title: String(localized: "Playlists"), state: playlists, playlist: true)
            }
            .navigationTitle("Add to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
            .alert(creatingPlaylist == true ? "New Playlist" : "New Collection", isPresented: Binding(get: { creatingPlaylist != nil }, set: { if !$0 { creatingPlaylist = nil } })) {
                TextField("Name", text: $newName)
                Button("Create") {
                    let playlist = creatingPlaylist ?? true
                    Task { await create(playlist: playlist) }
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel", role: .cancel) {}
            }
            .task { await load() }
        }
    }

    @ViewBuilder
    private func section(title: String, state: LoadState<[ItemCollection]>, playlist: Bool) -> some View {
        Section(title) {
            Button {
                newName = ""
                creatingPlaylist = playlist
            } label: {
                Label(playlist ? String(localized: "New Playlist…") : String(localized: "New Collection…"), systemImage: "plus")
            }
            switch state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)
            case .failed(let error):
                Text(error.userMessage)
                    .foregroundStyle(.secondary)
            case .loaded(let entries):
                ForEach(entries) { collection in
                    let contains = collection.items.contains { $0.id == itemID }
                    Button {
                        Task { await add(to: collection) }
                    } label: {
                        HStack {
                            CollectionRow(collection: collection)
                            if contains {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            } else if working == collection.id {
                                ProgressView()
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(contains || working != nil)
                }
            }
        }
    }

    private func load() async {
        let library = itemID.library
        do {
            let client = try Client.for(itemID.connectionID)
            if allowsCollections {
                async let collectionsPage = client.collections(library: library, page: 0, limit: 100)
                async let playlistsPage = client.playlists(library: library, page: 0, limit: 100)
                collections = .loaded(try await collectionsPage.items)
                playlists = .loaded(try await playlistsPage.items)
            } else {
                playlists = .loaded(try await client.playlists(library: library, page: 0, limit: 100).items)
            }
        } catch {
            collections = .failed(error)
            playlists = .failed(error)
        }
    }

    private func add(to collection: ItemCollection) async {
        working = collection.id
        defer { working = nil }
        do {
            try await Client.for(itemID.connectionID).addToCollection(collection.id, items: [itemID])
            alerts.succeed()
            dismiss()
        } catch {
            alerts.fail(error)
        }
    }

    private func create(playlist: Bool) async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            let id = try await Client.for(itemID.connectionID).createCollection(name: name, library: itemID.library, items: [itemID], playlist: playlist)
            alerts.succeed()
            dismiss()
            navigator.push(.item(id))
        } catch {
            alerts.fail(error)
        }
    }
}
