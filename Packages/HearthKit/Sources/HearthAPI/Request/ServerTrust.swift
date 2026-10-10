import CryptoKit
import Foundation
import Security

/// TLS server trust evaluation with support for user-pinned (self-signed) leaf certificates.
///
/// Public so other modules (downloads, streaming) can apply the same rules to their own sessions.
public enum ServerTrust {
    public enum Decision: Sendable, Equatable {
        /// The system trusts the certificate; continue with default handling.
        case systemTrusted
        /// The leaf certificate matches the pinned fingerprint; accept it.
        case pinned
        /// Not trusted. `sha256` is the leaf fingerprint the user may choose to trust.
        case untrusted(sha256: String?)
    }

    /// Lowercase hex SHA-256 of the DER encoded leaf certificate.
    public static func leafCertificateSHA256(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return nil
        }
        let data = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Normalises user/stored fingerprints (`AB:CD:…`, uppercase, whitespace) to lowercase hex.
    public static func normalizedFingerprint(_ fingerprint: String) -> String {
        fingerprint.lowercased().filter { $0.isHexDigit }
    }

    public static func evaluate(_ trust: SecTrust, pinnedSHA256: String?) -> Decision {
        let fingerprint = leafCertificateSHA256(trust)
        if let pinnedSHA256, let fingerprint, normalizedFingerprint(pinnedSHA256) == fingerprint {
            return .pinned
        }
        if SecTrustEvaluateWithError(trust, nil) {
            return .systemTrusted
        }
        return .untrusted(sha256: fingerprint)
    }

    /// Convenience for `URLSessionTaskDelegate` implementations.
    public static func handle(_ challenge: URLAuthenticationChallenge, pinnedSHA256: String?) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        switch evaluate(trust, pinnedSHA256: pinnedSHA256) {
        case .systemTrusted:
            return (.performDefaultHandling, nil)
        case .pinned:
            return (.useCredential, URLCredential(trust: trust))
        case .untrusted:
            return (.cancelAuthenticationChallenge, nil)
        }
    }
}
