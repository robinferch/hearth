import CryptoKit
import Foundation

/// Proof Key for Code Exchange (RFC 7636) helpers.
enum PKCE {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

    /// A random alphanumeric code verifier (64–128 characters as required by the spec).
    static func makeVerifier(length: Int = 64) -> String {
        precondition((43 ... 128).contains(length))
        var generator = SystemRandomNumberGenerator()
        return String((0 ..< length).map { _ in alphabet.randomElement(using: &generator)! })
    }

    /// `base64url(SHA256(verifier))` without padding.
    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
