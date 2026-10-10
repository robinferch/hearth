import CryptoKit
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

    private let entries = Mutex<[String: Entry]>([:])
    private let logger = Logger(category: "SessionTrust")

    /// Rebuilds the host table from the current connections.
    func update(connections: [Connection], credentials: any CredentialStoring) {
        var table = [String: Entry]()
        for connection in connections {
            let key = ClientIdentityKey.make(connection.host)
            var entry = table[key] ?? Entry()
            if let pin = connection.pinnedCertificateSHA256 {
                entry.pinnedSHA256 = Self.normalizedFingerprint(pin)
            }
            if entry.identity == nil, let certificate = credentials.clientCertificate(for: key) {
                entry.identity = try? PKCS12.importIdentity(certificate.pkcs12, passphrase: certificate.passphrase)
            }
            table[key] = entry
        }
        entries.withLock { $0 = table }
    }

    func identity(for host: URL) -> ClientIdentity? {
        entries.withLock { $0[ClientIdentityKey.make(host)]?.identity }
    }

    static func normalizedFingerprint(_ value: String) -> String {
        value.lowercased().filter { $0.isHexDigit }
    }

    static func sha256(of certificate: SecCertificate) -> String {
        let data = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func entry(for space: URLProtectionSpace) -> Entry? {
        let scheme = space.protocol ?? "https"
        let key = "\(scheme.lowercased())://\(space.host.lowercased()):\(space.port)"
        return entries.withLock { $0[key] }
    }

    /// Handles an authentication challenge for one of Hearth's sessions.
    func handle(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = space.serverTrust else { return (.performDefaultHandling, nil) }
            if SecTrustEvaluateWithError(trust, nil) {
                return (.performDefaultHandling, nil)
            }
            guard let pin = entry(for: space)?.pinnedSHA256,
                  let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let leaf = chain.first
            else {
                return (.performDefaultHandling, nil)
            }
            if Self.sha256(of: leaf) == pin {
                return (.useCredential, URLCredential(trust: trust))
            }
            logger.error("Pinned certificate mismatch for \(space.host, privacy: .public)")
            return (.cancelAuthenticationChallenge, nil)
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
