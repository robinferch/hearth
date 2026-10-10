import Foundation
import HearthModel

/// Sends a single `URLRequest` and maps transport failures to `APIError`. No retries, no status handling.
struct HTTPTransport: Sendable {
    let session: URLSession
    let pinnedSHA256: String?
    /// Passed to the client identity provider on client certificate challenges.
    let identityID: ConnectionID

    func send(_ request: URLRequest, followsRedirects: Bool = true) async throws(APIError) -> (Data, HTTPURLResponse) {
        let delegate = TaskSecurityDelegate(pinnedSHA256: pinnedSHA256, identityID: identityID, followsRedirects: followsRedirects)
        do {
            let (data, response) = try await session.data(for: request, delegate: delegate)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.invalidResponse(statusCode: -1)
            }
            return (data, http)
        } catch {
            if let fingerprint = delegate.untrustedFingerprint {
                throw .untrustedCertificate(sha256: fingerprint)
            }
            throw Self.map(error)
        }
    }

    static func map(_ error: any Error) -> APIError {
        if let apiError = error as? APIError {
            return apiError
        }
        if error is CancellationError {
            return .cancelled
        }
        guard let urlError = error as? URLError else {
            return .transport(String(describing: error))
        }
        switch urlError.code {
        case .cancelled:
            return .cancelled
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .timedOut, .networkConnectionLost, .secureConnectionFailed, .resourceUnavailable:
            return .unreachable
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return .untrustedCertificate(sha256: "")
        case .badURL, .unsupportedURL:
            return .invalidURL
        default:
            return .transport(urlError.localizedDescription)
        }
    }
}

extension APIError {
    /// Whether another attempt could succeed.
    var isRetryable: Bool {
        switch self {
        case .unreachable, .transport:
            true
        case .invalidResponse(let status):
            status >= 500 || status == 408 || status == 429
        default:
            false
        }
    }
}
