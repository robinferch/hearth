import AuthenticationServices
import HearthAPI
import HearthData
import HearthModel
import HearthUI
import SwiftUI
import UniformTypeIdentifiers

/// Add a server (or re-authorize an existing connection).
struct AddConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(AlertCenter.self) private var alerts

    @State private var model: AddConnectionModel
    @State private var isImportingCertificate = false
    @State private var showsHeaders: Bool
    @State private var didAutoLaunchOpenID = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case host
        case username
        case password
    }

    init(reauthorizing connection: Connection? = nil) {
        _model = State(initialValue: AddConnectionModel(reauthorizing: connection))
        _showsHeaders = State(initialValue: !(connection?.headers.isEmpty ?? true))
    }

    private var isReauthorizing: Bool { model.reauthorizing != nil }

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                if model.status == nil {
                    headersSection
                    certificateSection
                    knownServersSection
                } else {
                    authenticationSections
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isReauthorizing ? String(localized: "Sign In Again") : String(localized: "Add Server"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") {
                        if isReauthorizing {
                            HearthData.shared.connections.connectionNeedingReauthorization = nil
                        }
                        dismiss()
                    }
                }
                if model.status == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Continue", systemImage: "arrow.right") {
                            Task { await model.verify() }
                        }
                        .disabled(model.host == nil || model.phase == .verifying)
                    }
                }
            }
            .fileImporter(isPresented: $isImportingCertificate, allowedContentTypes: [.pkcs12]) { result in
                switch result {
                case .success(let url):
                    model.importClientCertificate(from: url)
                case .failure(let error):
                    model.clientCertificateError = error.localizedDescription
                }
            }
            .alert("Untrusted Certificate", isPresented: Binding(get: { model.pendingCertificate != nil }, set: { if !$0 { model.pendingCertificate = nil } })) {
                Button("Trust Certificate") {
                    Task { await model.trustPendingCertificate() }
                }
                Button("Cancel", role: .cancel) {
                    model.pendingCertificate = nil
                }
            } message: {
                Text("The server's certificate is not trusted by your device. Only trust it if you recognize this SHA-256 fingerprint:\n\n\(formattedFingerprint(model.pendingCertificate ?? ""))")
            }
            .onAppear {
                if model.hostInput.isEmpty {
                    focusedField = .host
                } else if isReauthorizing {
                    Task { await model.verify() }
                }
            }
            .onChange(of: model.status) { _, status in
                guard let status else { return }
                if status.authMethods == [.openID] || (status.openIDAutoLaunch && status.authMethods.contains(.openID)) {
                    model.authMethod = .openID
                    if !didAutoLaunchOpenID {
                        didAutoLaunchOpenID = true
                        Task { await startOpenID() }
                    }
                } else if model.authMethod == .local {
                    focusedField = model.username.isEmpty ? .username : .password
                }
            }
        }
        .interactiveDismissDisabled(model.isSigningIn)
    }

    // MARK: Server

    private var serverSection: some View {
        Section {
            TextField("Server Address", text: $model.hostInput, prompt: Text(verbatim: "https://abs.example.com"))
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.continue)
                .focused($focusedField, equals: .host)
                .disabled(isReauthorizing)
                .onSubmit { Task { await model.verify() } }
                .onChange(of: model.hostInput) { model.hostChanged() }

            switch model.phase {
            case .enterURL:
                if let error = model.errorMessage, model.status == nil {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.subheadline)
                }
            case .verifying:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Connecting…")
                        .foregroundStyle(.secondary)
                }
            case .verified(let status):
                Label {
                    if let version = status.serverVersion {
                        Text("Server version \(version)")
                    } else {
                        Text("Connected")
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                if status.isOutdated {
                    Label {
                        Text("This server is outdated. Update to audiobookshelf \(ServerStatus.minimumRecommendedVersion) or later for secure sign-in tokens.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.subheadline)
                }
            }
        } header: {
            Text("Server")
        } footer: {
            if model.status == nil {
                Text(verbatim: "http(s)://host(:port)(/path)")
            }
        }
    }

    // MARK: Headers

    private var headersSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showsHeaders) {
                HeadersEditor(headers: $model.headers)
            } label: {
                Label {
                    HStack {
                        Text("Custom Headers")
                        if !model.validHeaders.isEmpty {
                            Spacer()
                            Text(model.validHeaders.count, format: .number)
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "list.bullet.rectangle")
                }
            }
        } footer: {
            Text("Sent with every request, for example to pass a reverse proxy or Cloudflare Access.")
        }
    }

    // MARK: Client certificate

    private var certificateSection: some View {
        Section {
            if let name = model.clientCertificateName {
                LabeledContent {
                    Button("Remove", role: .destructive) {
                        model.removeClientCertificate()
                    }
                } label: {
                    Label(name, systemImage: "checkmark.seal")
                }
                SecureField("Passphrase", text: $model.clientCertificatePassphrase)
                    .textContentType(.password)
            } else {
                Button {
                    isImportingCertificate = true
                } label: {
                    Label("Import Client Certificate…", systemImage: "lock.doc")
                }
            }
            if let error = model.clientCertificateError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.subheadline)
            }
        } footer: {
            Text("Only needed if your server requires a client certificate (mutual TLS). Import a .p12 file.")
        }
    }

    // MARK: Known servers

    @ViewBuilder
    private var knownServersSection: some View {
        let known = HearthData.shared.connections.knownServers
        if !known.isEmpty, !isReauthorizing {
            Section("Recent Servers") {
                ForEach(known) { server in
                    Button {
                        model.fill(from: server)
                        Task { await model.verify() }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.host.host() ?? server.host.absoluteString)
                                .foregroundStyle(.primary)
                            Text(server.username)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: Authentication

    @ViewBuilder
    private var authenticationSections: some View {
        if let status = model.status {
            if status.authMethods.count > 1 {
                Section {
                    Picker("Sign-In Method", selection: $model.authMethod) {
                        Text("Password").tag(AuthMethod.local)
                        Text(status.openIDButtonText ?? String(localized: "Single Sign-On")).tag(AuthMethod.openID)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }

            switch model.authMethod {
            case .local:
                Section {
                    TextField("Username", text: $model.username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focusedField, equals: .username)
                        .onSubmit { focusedField = .password }
                    SecureField("Password", text: $model.password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($focusedField, equals: .password)
                        .onSubmit { Task { await signIn() } }
                } header: {
                    Text("Account")
                } footer: {
                    errorFooter
                }
                Section {
                    Button {
                        Task { await signIn() }
                    } label: {
                        signInLabel(String(localized: "Sign In"))
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!model.canSignIn)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            case .openID:
                Section {
                    Button {
                        Task { await startOpenID() }
                    } label: {
                        signInLabel(status.openIDButtonText ?? String(localized: "Sign In with SSO"))
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(model.isSigningIn)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        errorFooter
                        Text("Add \(ServerAuthenticator.callbackURL) to the allowed redirect URIs in your audiobookshelf authentication settings.")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var errorFooter: some View {
        if let error = model.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private func signInLabel(_ title: String) -> some View {
        HStack {
            if model.isSigningIn {
                ProgressView()
                    .tint(.white)
            }
            Text(title)
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    // MARK: Actions

    private func signIn() async {
        guard model.canSignIn else { return }
        if await model.signIn() {
            alerts.succeed()
            dismiss()
        }
    }

    private func startOpenID() async {
        guard let authorization = await model.beginOpenID() else { return }
        let headerFields = Dictionary(model.validHeaders.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
        do {
            let callbackURL = try await webAuthenticationSession.authenticate(
                using: authorization.authorizationURL,
                callback: .customScheme(ServerAuthenticator.callbackScheme),
                preferredBrowserSession: .ephemeral,
                additionalHeaderFields: headerFields
            )
            if await model.completeOpenID(callbackURL: callbackURL, codeVerifier: authorization.codeVerifier) {
                alerts.succeed()
                dismiss()
            }
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func formattedFingerprint(_ hex: String) -> String {
        let uppercased = hex.uppercased().filter { !$0.isWhitespace && $0 != ":" }
        var pairs: [String] = []
        var index = uppercased.startIndex
        while index < uppercased.endIndex {
            let next = uppercased.index(index, offsetBy: 2, limitedBy: uppercased.endIndex) ?? uppercased.endIndex
            pairs.append(String(uppercased[index..<next]))
            index = next
        }
        return pairs.joined(separator: ":")
    }
}

/// Key / value editor for custom HTTP headers.
struct HeadersEditor: View {
    @Binding var headers: [HTTPHeader]

    var body: some View {
        ForEach($headers) { $header in
            VStack(spacing: 6) {
                TextField("Header", text: $header.key, prompt: Text(verbatim: "X-Api-Key"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                TextField("Value", text: $header.value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .onDelete { headers.remove(atOffsets: $0) }
        Button {
            withAnimation { headers.append(HTTPHeader(key: "", value: "")) }
        } label: {
            Label("Add Header", systemImage: "plus.circle")
        }
    }
}

/// Re-login sheet shown automatically when a connection's session expired.
struct ReauthorizationSheet: View {
    let connection: Connection

    var body: some View {
        AddConnectionView(reauthorizing: connection)
    }
}
