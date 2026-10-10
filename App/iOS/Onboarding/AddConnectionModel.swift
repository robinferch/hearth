import Foundation
import HearthAPI
import HearthData
import HearthModel
import Observation
import OSLog

/// State machine of the add-connection / re-authorization flow.
@MainActor
@Observable
final class AddConnectionModel {
    enum Phase: Equatable {
        case enterURL
        case verifying
        case verified(ServerStatus)
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hearth", category: "AddConnection")

    /// Connection being re-authorized, if any.
    let reauthorizing: Connection?

    var hostInput: String
    var headers: [HTTPHeader]
    var phase: Phase = .enterURL
    var errorMessage: String?

    /// SHA-256 the user chose to trust.
    var pinnedCertificate: String?
    /// Untrusted certificate awaiting the user's decision.
    var pendingCertificate: String?

    /// Imported client identity (.p12).
    var clientCertificateData: Data?
    var clientCertificateName: String?
    var clientCertificatePassphrase = ""
    var clientCertificateError: String?

    var authMethod: AuthMethod = .local
    var username: String
    var password = ""
    var isSigningIn = false

    init(reauthorizing connection: Connection? = nil) {
        reauthorizing = connection
        hostInput = connection?.host.absoluteString ?? ""
        headers = connection?.headers ?? []
        username = connection?.username ?? ""
        pinnedCertificate = connection?.pinnedCertificateSHA256
    }

    var status: ServerStatus? {
        if case .verified(let status) = phase { status } else { nil }
    }

    var host: URL? {
        Connection.normalizedHost(hostInput)
    }

    var validHeaders: [HTTPHeader] {
        headers.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var canSignIn: Bool {
        status != nil && !isSigningIn && !username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: Verify

    func hostChanged() {
        if phase != .enterURL {
            phase = .enterURL
        }
        errorMessage = nil
    }

    func verify() async {
        guard let host else {
            errorMessage = String(localized: "Enter a valid server address, for example https://abs.example.com.")
            return
        }
        hostInput = host.absoluteString
        errorMessage = nil
        guard importClientCertificate(for: host) else {
            return
        }
        phase = .verifying
        do {
            let status = try await ServerAuthenticator.status(host: host, headers: validHeaders, pinnedCertificateSHA256: pinnedCertificate)
            guard status.isInitialized else {
                phase = .enterURL
                errorMessage = APIError.serverNotInitialized.userMessage
                return
            }
            if !status.authMethods.contains(authMethod) {
                authMethod = status.authMethods.first ?? .local
            }
            phase = .verified(status)
        } catch APIError.untrustedCertificate(let sha256) {
            phase = .enterURL
            pendingCertificate = sha256
        } catch {
            phase = .enterURL
            errorMessage = error.userMessage
            Self.logger.notice("Server verification failed: \(String(describing: error), privacy: .public)")
        }
    }

    func trustPendingCertificate() async {
        pinnedCertificate = pendingCertificate
        pendingCertificate = nil
        await verify()
    }

    // MARK: Client certificate

    func importClientCertificate(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        do {
            clientCertificateData = try Data(contentsOf: url)
            clientCertificateName = url.lastPathComponent
            clientCertificateError = nil
        } catch {
            clientCertificateError = error.localizedDescription
        }
    }

    func removeClientCertificate() {
        clientCertificateData = nil
        clientCertificateName = nil
        clientCertificatePassphrase = ""
        clientCertificateError = nil
    }

    /// Stores the imported .p12 for `host` through HearthData (validates the passphrase). HearthData supplies it to
    /// every request against that host, including the unauthenticated ones made while adding the connection.
    func importClientCertificate(for host: URL) -> Bool {
        guard let data = clientCertificateData else { return true }
        do {
            try HearthData.shared.connections.importClientCertificate(data, passphrase: clientCertificatePassphrase, for: host)
            clientCertificateError = nil
            return true
        } catch .invalidPassphrase {
            clientCertificateError = String(localized: "The passphrase is incorrect.")
        } catch .noIdentity {
            clientCertificateError = String(localized: "The file doesn't contain a client certificate.")
        } catch {
            clientCertificateError = String(localized: "The certificate could not be opened. Check the passphrase.")
        }
        return false
    }

    // MARK: Sign in

    func signIn() async -> Bool {
        guard let host, let status else { return false }
        guard importClientCertificate(for: host) else { return false }
        isSigningIn = true
        errorMessage = nil
        defer { isSigningIn = false }
        do {
            let result = try await ServerAuthenticator.login(host: host, headers: validHeaders, username: username.trimmingCharacters(in: .whitespaces), password: password, pinnedCertificateSHA256: pinnedCertificate)
            await store(result, host: host, status: status)
            return true
        } catch {
            errorMessage = error.userMessage
            return false
        }
    }

    /// Completes an OpenID login with the callback URL from the web authentication session.
    func completeOpenID(callbackURL: URL, codeVerifier: String) async -> Bool {
        guard let host, let status else { return false }
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            let result = try await ServerAuthenticator.completeOpenID(host: host, headers: validHeaders, callbackURL: callbackURL, codeVerifier: codeVerifier, pinnedCertificateSHA256: pinnedCertificate)
            await store(result, host: host, status: status)
            return true
        } catch {
            errorMessage = error.userMessage
            return false
        }
    }

    func beginOpenID() async -> OpenIDAuthorization? {
        guard let host else { return nil }
        guard importClientCertificate(for: host) else { return nil }
        errorMessage = nil
        do {
            return try await ServerAuthenticator.beginOpenID(host: host, headers: validHeaders, pinnedCertificateSHA256: pinnedCertificate)
        } catch {
            errorMessage = error.userMessage
            return nil
        }
    }

    private func store(_ result: LoginResult, host: URL, status: ServerStatus) async {
        let connections = HearthData.shared.connections
        let connection = Connection(
            host: host,
            username: result.username,
            userID: result.userID,
            headers: validHeaders,
            serverVersion: status.serverVersion,
            pinnedCertificateSHA256: pinnedCertificate
        )
        if let reauthorizing, reauthorizing.id == connection.id {
            var updated = reauthorizing
            updated.headers = validHeaders
            updated.serverVersion = status.serverVersion
            updated.pinnedCertificateSHA256 = pinnedCertificate
            updated.userID = result.userID
            await connections.update(updated)
            await connections.updateTokens(result.tokens, for: updated.id)
            connections.connectionNeedingReauthorization = nil
        } else {
            await connections.add(connection, tokens: result.tokens)
        }
    }

    // MARK: Headers

    func addHeader() {
        headers.append(HTTPHeader(key: "", value: ""))
    }

    func removeHeaders(at offsets: IndexSet) {
        headers.remove(atOffsets: offsets)
    }

    func fill(from server: KnownServer) {
        hostInput = server.host.absoluteString
        username = server.username
        hostChanged()
    }
}
