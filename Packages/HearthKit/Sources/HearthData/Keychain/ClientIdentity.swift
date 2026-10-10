import HearthAPI
import Foundation
import HearthModel
import os
import Security
import Synchronization

public enum ClientCertificateError: Error, Sendable, Equatable {
    case invalidPassphrase
    case noIdentity
    case importFailed(status: Int32)
}

/// A TLS client identity (certificate + private key) used for mutual TLS.
public struct ClientIdentity: @unchecked Sendable {
    public let identity: SecIdentity
    public let certificates: [SecCertificate]

    public var credential: URLCredential {
        URLCredential(identity: identity, certificates: certificates.isEmpty ? nil : certificates, persistence: .forSession)
    }
}

/// Key used to store client certificates: scheme + host + port of the server.
enum ClientIdentityKey {
    static func make(_ host: URL) -> String {
        let scheme = host.scheme?.lowercased() ?? "https"
        let name = host.host()?.lowercased() ?? host.absoluteString
        let port = host.port ?? (scheme == "http" ? 80 : 443)
        return "\(scheme)://\(name):\(port)"
    }
}

enum PKCS12 {
    static func importIdentity(_ data: Data, passphrase: String) throws(ClientCertificateError) -> ClientIdentity {
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: passphrase] as CFDictionary
        let status = SecPKCS12Import(data as CFData, options, &items)
        switch status {
        case errSecSuccess:
            break
        case errSecAuthFailed, errSecPkcs12VerifyFailure:
            throw .invalidPassphrase
        default:
            throw .importFailed(status: status)
        }
        guard let entries = items as? [[String: Any]], let first = entries.first, let rawIdentity = first[kSecImportItemIdentity as String] else {
            throw .noIdentity
        }
        // swiftlint:disable:next force_cast
        let identity = rawIdentity as! SecIdentity
        let chain = (first[kSecImportItemCertChain as String] as? [SecCertificate]) ?? []
        // The leaf is part of the identity; pass intermediates only.
        return ClientIdentity(identity: identity, certificates: Array(chain.dropFirst()))
    }
}

/// Resolves server trust (pinned self-signed certificates) and client certificates for Hearth's own
/// `URLSession`s (downloads, images). Shared by every session delegate.
final class SessionTrust: Sendable {
    private struct Entry {
        var pinnedSHA256: String?
        var identity: ClientIdentity?
    }

    private struct State {
        var entries: [String: Entry] = [:]
        /// Connection id → host key.
        var hosts: [ConnectionID: String] = [:]
    }

    private let state = Mutex(State())
    private let credentials: any CredentialStoring

    init(credentials: any CredentialStoring) {
        self.credentials = credentials
    }

    /// Rebuilds the host table from the current connections.
    func update(connections: [Connection]) {
        var table = [String: Entry]()
        var hosts = [ConnectionID: String]()
        for connection in connections {
            let key = ClientIdentityKey.make(connection.host)
            hosts[connection.id] = key
            var entry = table[key] ?? Entry()
            if let pin = connection.pinnedCertificateSHA256 {
                entry.pinnedSHA256 = ServerTrust.normalizedFingerprint(pin)
            }
            if entry.identity == nil, let certificate = credentials.clientCertificate(for: key) {
                entry.identity = try? PKCS12.importIdentity(certificate.pkcs12, passphrase: certificate.passphrase)
            }
            table[key] = entry
        }
        state.withLock {
            $0.entries = table
            $0.hosts = hosts
        }
    }

    func identity(for host: URL) -> ClientIdentity? {
        let key = ClientIdentityKey.make(host)
        if let identity = state.withLock({ $0.entries[key]?.identity }) {
            return identity
        }
        guard let certificate = credentials.clientCertificate(for: key) else { return nil }
        return try? PKCS12.importIdentity(certificate.pkcs12, passphrase: certificate.passphrase)
    }

    /// Backs `APIClientFactory.clientIdentityProvider`: resolves real and provisional (`provisional:<host>`) ids.
    func identity(forConnectionID id: ConnectionID) -> SecIdentity? {
        let provisionalPrefix = "provisional:"
        if id.hasPrefix(provisionalPrefix), let host = URL(string: String(id.dropFirst(provisionalPrefix.count))) {
            return identity(for: host)?.identity
        }
        guard let key = state.withLock({ $0.hosts[id] }) else { return nil }
        if let identity = state.withLock({ $0.entries[key]?.identity }) {
            return identity.identity
        }
        guard let certificate = credentials.clientCertificate(for: key) else { return nil }
        return (try? PKCS12.importIdentity(certificate.pkcs12, passphrase: certificate.passphrase))?.identity
    }

    private func entry(for space: URLProtectionSpace) -> Entry? {
        let scheme = space.protocol ?? "https"
        let key = "\(scheme.lowercased())://\(space.host.lowercased()):\(space.port)"
        return state.withLock { $0.entries[key] }
    }

    /// Handles an authentication challenge for one of Hearth's sessions (downloads, images).
    func handle(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            return ServerTrust.handle(challenge, pinnedSHA256: entry(for: space)?.pinnedSHA256)
        case NSURLAuthenticationMethodClientCertificate:
            if let identity = entry(for: space)?.identity {
                return (.useCredential, identity.credential)
            }
            return (.performDefaultHandling, nil)
        default:
            return (.performDefaultHandling, nil)
        }
    }
}
