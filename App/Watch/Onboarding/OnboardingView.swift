import HearthAPI
import HearthData
import HearthModel
import HearthUI
import SwiftUI

/// Shown while the watch has no signed-in connection: sign in through the iPhone, or manually.
struct OnboardingView: View {
    @State private var errorMessage: String?
    @State private var showsManualSignIn = false

    private var link: PhoneLink { .shared }
    private var session: WatchSyncSession { .shared }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.tint)
                        .symbolEffect(.pulse, isActive: link.isRequestingCredentials)
                        .accessibilityHidden(true)

                    Text("Open Hearth on your iPhone to sign in")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        Task { await requestFromPhone() }
                    } label: {
                        if link.isRequestingCredentials {
                            ProgressView()
                        } else {
                            Label("Sign In with iPhone", systemImage: "iphone")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(link.isRequestingCredentials)

                    Button("Sign In Manually") {
                        showsManualSignIn = true
                    }
                    .buttonStyle(.bordered)
                }
                .scenePadding(.horizontal)
            }
            .navigationTitle("Hearth")
            .navigationDestination(isPresented: $showsManualSignIn) {
                ManualSignInView()
            }
            .task {
                await session.waitUntilActivated()
                if session.isReachable {
                    await requestFromPhone()
                }
            }
            .onChange(of: session.isReachable) { _, reachable in
                if reachable {
                    Task { await requestFromPhone() }
                }
            }
        }
    }

    private func requestFromPhone() async {
        errorMessage = nil
        guard session.isReachable else {
            errorMessage = String(localized: "Your iPhone isn't reachable. Open Hearth on it and keep it nearby.")
            return
        }
        do {
            let count = try await link.requestCredentials()
            if count == 0, HearthData.shared.connections.signedInConnections.isEmpty {
                errorMessage = String(localized: "Hearth on your iPhone isn't signed in to a server yet.")
            }
        } catch {
            errorMessage = String(localized: "Your iPhone didn't respond. Open Hearth on it and try again.")
        }
    }
}

/// Fallback sign-in on the watch: server URL, username, password.
struct ManualSignInView: View {
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                TextField("Server URL", text: $server)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("Password", text: $password)
                    .textContentType(.password)
            } footer: {
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                } else {
                    Text("For example https://abs.example.com")
                }
            }

            Button {
                Task { await signIn() }
            } label: {
                if isSigningIn {
                    ProgressView()
                } else {
                    Text("Sign In")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSigningIn || server.isEmpty || username.isEmpty)
        }
        .navigationTitle("Sign In")
    }

    private func signIn() async {
        guard let host = Connection.normalizedHost(server) else {
            errorMessage = String(localized: "Enter a valid server address.")
            return
        }
        isSigningIn = true
        errorMessage = nil
        defer { isSigningIn = false }
        do {
            let status = try await ServerAuthenticator.status(host: host, headers: [])
            guard status.authMethods.contains(.local) else {
                errorMessage = String(localized: "This server only allows single sign-on. Sign in on your iPhone instead.")
                return
            }
            let result = try await ServerAuthenticator.login(host: host, headers: [], username: username.trimmingCharacters(in: .whitespaces), password: password)
            let connection = Connection(host: host, username: result.username, userID: result.userID, serverVersion: status.serverVersion)
            await HearthData.shared.connections.add(connection, tokens: result.tokens)
            // Share the new session with the phone.
            PhoneLink.shared.checkTokens()
        } catch {
            errorMessage = (error as? APIError).map(\.watchMessage) ?? error.localizedDescription
        }
    }
}

extension APIError {
    /// Short, user-facing explanation.
    var watchMessage: String {
        switch self {
        case .offline: String(localized: "Your watch is offline.")
        case .unreachable, .transport: String(localized: "The server couldn't be reached.")
        case .unauthorized: String(localized: "Wrong username or password.")
        case .invalidURL: String(localized: "Enter a valid server address.")
        case .serverNotInitialized: String(localized: "This server hasn't been set up yet.")
        case .unsupportedAuthMethod: String(localized: "This sign-in method isn't supported.")
        case .untrustedCertificate: String(localized: "The server's certificate isn't trusted. Sign in on your iPhone first.")
        case .notFound, .invalidResponse, .decoding, .cancelled: String(localized: "Something went wrong. Try again.")
        }
    }
}
