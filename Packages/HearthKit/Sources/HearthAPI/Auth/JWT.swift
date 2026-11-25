import Foundation
import HearthModel

/// Minimal JWT inspection (no signature verification) to refresh access tokens before they expire.
///
/// Servers 2.26+ issue access tokens that expire after an hour; legacy tokens aren't JWTs with `exp` and never expire.
enum JWT {
    /// The `exp` claim of `token`, or `nil` if it isn't a JWT or has no expiry.
    static func expiry(of token: String) -> Date? {
        date("exp", of: token)
    }

    /// The `iat` claim of `token` (when the server issued it), or `nil`.
    static func issuedAt(of token: String) -> Date? {
        date("iat", of: token)
    }

    private static func date(_ claim: String, of token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = (claims[claim] as? NSNumber)?.doubleValue
        else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    /// The bearer token of an `Authorization` header value.
    static func bearerToken(in header: String?) -> String? {
        guard let header, header.hasPrefix("Bearer ") else { return nil }
        let token = String(header.dropFirst("Bearer ".count))
        return token.isEmpty ? nil : token
    }
}

public extension AuthTokens {
    /// When the server issued the refresh token (`iat`), or `nil` for legacy tokens. The server rotates the refresh
    /// token on every refresh, so of two token pairs of the same session the one issued later is the valid one. Server
    /// time, so it can be compared across devices.
    var refreshTokenIssuedAt: Date? {
        refreshToken.flatMap(JWT.issuedAt(of:))
    }

    /// Whether these tokens come from a later refresh of the same session than `other` (`nil` when unknown).
    func isNewer(than other: AuthTokens) -> Bool? {
        guard let issued = refreshTokenIssuedAt, let otherIssued = other.refreshTokenIssuedAt else { return nil }
        return issued > otherIssued
    }
}
