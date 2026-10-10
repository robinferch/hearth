import HearthAPI
import HearthData
import HearthModel
import HearthUI
import SwiftUI

/// List of connections (red when offline), add, remove all.
struct ConnectionsSettingsView: View {
    @State private var isAdding = false
    @State private var confirmsRemoveAll = false

    private var connections: ConnectionStore { HearthData.shared.connections }

    var body: some View {
        List {
            Section {
                ForEach(connections.connections) { connection in
                    NavigationLink {
                        ConnectionDetailView(connectionID: connection.id)
                    } label: {
                        ConnectionRow(connection: connection, status: connections.status[connection.id])
                    }
                }
                Button {
                    isAdding = true
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
            } footer: {
                Text("Hearth can connect to several audiobookshelf servers and accounts at the same time.")
            }

            if !connections.connections.isEmpty {
                Section {
                    Button("Remove All Servers", role: .destructive) {
                        confirmsRemoveAll = true
                    }
                }
            }
        }
        .navigationTitle("Connections")
        .sheet(isPresented: $isAdding) {
            AddConnectionView()
        }
        .confirmationDialog("Remove all servers?", isPresented: $confirmsRemoveAll, titleVisibility: .visible) {
            Button("Remove All", role: .destructive) {
                Task { await connections.removeAll() }
            }
        } message: {
            Text("You will be signed out of every server. Downloads are removed.")
        }
    }
}

private struct ConnectionRow: View {
    let connection: Connection
    let status: ConnectionStatus?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .foregroundStyle(statusColor)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.host.host() ?? connection.host.absoluteString)
                    .foregroundStyle(status == .offline || status == .unauthorized ? .red : .primary)
                Text(connection.username)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(statusText)
                .font(.caption)
                .foregroundStyle(statusColor)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        switch status {
        case .online: .green
        case .offline, .unauthorized: .red
        case .loading, nil: .secondary
        }
    }

    private var statusText: String {
        switch status {
        case .online: String(localized: "Online")
        case .offline: String(localized: "Offline")
        case .unauthorized: String(localized: "Signed Out")
        case .loading, nil: String(localized: "Connecting…")
        }
    }
}

/// User, server, version, legacy-auth hint, headers, re-authorize, remove.
struct ConnectionDetailView: View {
    let connectionID: ConnectionID

    @Environment(\.dismiss) private var dismiss
    @State private var headers: [HTTPHeader] = []
    @State private var isLegacy = false
    @State private var confirmsRemove = false
    @State private var isSaving = false

    private var connections: ConnectionStore { HearthData.shared.connections }

    var body: some View {
        if let connection = connections.connection(connectionID) {
            Form {
                Section("Account") {
                    LabeledContent("User", value: connection.username)
                    LabeledContent("Server", value: connection.host.absoluteString)
                    if let version = connection.serverVersion {
                        LabeledContent("Version", value: version)
                    }
                    LabeledContent("Added", value: connection.addedAt.formatted(date: .abbreviated, time: .omitted))
                    if connection.pinnedCertificateSHA256 != nil {
                        Label("Trusted self-signed certificate", systemImage: "checkmark.seal")
                            .foregroundStyle(.secondary)
                    }
                }

                if isLegacy {
                    Section {
                        Label {
                            Text("This connection uses a legacy token that never expires. Update your server to audiobookshelf \(ServerStatus.minimumRecommendedVersion) or later and sign in again for secure, refreshable tokens.")
                        } icon: {
                            Image(systemName: "exclamationmark.shield")
                                .foregroundStyle(.orange)
                        }
                        .font(.subheadline)
                    }
                }

                Section {
                    HeadersEditor(headers: $headers)
                } header: {
                    Text("Custom Headers")
                } footer: {
                    if headers != connection.headers {
                        Button {
                            save(connection)
                        } label: {
                            if isSaving {
                                ProgressView()
                            } else {
                                Text("Save Headers")
                            }
                        }
                        .buttonStyle(.glassProminent)
                        .padding(.top, 8)
                    }
                }

                Section {
                    Button {
                        connections.connectionNeedingReauthorization = connection.id
                    } label: {
                        Label("Sign In Again", systemImage: "person.badge.key")
                    }
                    Button(role: .destructive) {
                        confirmsRemove = true
                    } label: {
                        Label("Remove Server", systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(connection.host.host() ?? connection.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: connectionID) {
                headers = connection.headers
                isLegacy = await connections.isUsingLegacyAuthentication(connectionID)
            }
            .confirmationDialog("Remove this server?", isPresented: $confirmsRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    Task {
                        await connections.remove(connectionID)
                        ClientIdentityStore.delete(connectionID)
                        dismiss()
                    }
                }
            } message: {
                Text("You will be signed out and its downloads are removed.")
            }
        } else {
            ContentUnavailableView("Server Removed", systemImage: "server.rack")
        }
    }

    private func save(_ connection: Connection) {
        isSaving = true
        var updated = connection
        updated.headers = headers.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
        Task {
            await connections.update(updated)
            isSaving = false
        }
    }
}
