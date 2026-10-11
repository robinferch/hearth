import Foundation

/// Bearer tokens in streaming headers expire (servers 2.26+: about an hour), but an `AVURLAsset` keeps the headers it
/// was created with. These helpers decide when player items need fresh headers.
enum StreamingAuth {
    /// Rebuild before resuming when the token expires within this interval.
    static let refreshMargin: TimeInterval = 2 * 60
    /// Minimum time between two authorization recoveries (prevents loops with a server that keeps rejecting).
    static let recoveryInterval: TimeInterval = 30

    /// Expiry (`exp` claim) of the bearer token in `headers`; `nil` without a JWT (legacy tokens never expire).
    static func tokenExpiry(in headers: [String: String]) -> Date? {
        guard let value = headers.first(where: { $0.key.caseInsensitiveCompare("Authorization") == .orderedSame })?.value,
              value.hasPrefix("Bearer ") else { return nil }
        let parts = value.dropFirst("Bearer ".count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = (claims["exp"] as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// Whether the streaming token expired or expires within `refreshMargin`.
    static func needsRefresh(headers: [String: String], now: Date) -> Bool {
        guard let expiry = tokenExpiry(in: headers) else { return false }
        return expiry.timeIntervalSince(now) < refreshMargin
    }

    /// Whether a player item failure was an HTTP 401/403: AVFoundation reports it as `NSURLErrorDomain`
    /// `userAuthenticationRequired` (possibly as an underlying error), in the error log's status code, or in texts
    /// like "HTTP 401: Unauthorized".
    static func isAuthorizationFailure(statusCode: Int?, error: (any Error)? = nil, texts: [String?]) -> Bool {
        if let statusCode, statusCode == 401 || statusCode == 403 {
            return true
        }
        var current = error.map { $0 as NSError }
        while let nsError = current {
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorUserAuthenticationRequired || nsError.code == NSURLErrorUserCancelledAuthentication {
                return true
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return texts.contains { text in
            guard let text else { return false }
            return text.range(of: #"\b(401|403)\b"#, options: .regularExpression) != nil
        }
    }
}
