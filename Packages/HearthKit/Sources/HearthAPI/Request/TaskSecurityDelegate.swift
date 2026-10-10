import Foundation
import HearthModel
import Synchronization

/// Per-task delegate handling redirects, server trust (pinning) and client certificates.
///
/// A fresh instance is used for every task so a trust failure can be attributed to the request that caused it.
final class TaskSecurityDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let pinnedSHA256: String?
    private let identityID: ConnectionID
    private let followsRedirects: Bool
    private let rejectedFingerprint = Mutex<String?>(nil)

    init(pinnedSHA256: String?, identityID: ConnectionID, followsRedirects: Bool = true) {
        self.pinnedSHA256 = pinnedSHA256
        self.identityID = identityID
        self.followsRedirects = followsRedirects
    }

    /// Fingerprint of a leaf certificate that failed evaluation during this task.
    var untrustedFingerprint: String? {
        rejectedFingerprint.withLock { $0 }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        followsRedirects ? request : nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        handle(challenge)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        handle(challenge)
    }

    private func handle(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust else {
                return (.performDefaultHandling, nil)
            }
            switch ServerTrust.evaluate(trust, pinnedSHA256: pinnedSHA256) {
            case .systemTrusted:
                return (.performDefaultHandling, nil)
            case .pinned:
                return (.useCredential, URLCredential(trust: trust))
            case .untrusted(let sha256):
                rejectedFingerprint.withLock { $0 = sha256 ?? "" }
                return (.cancelAuthenticationChallenge, nil)
            }
        case NSURLAuthenticationMethodClientCertificate:
            if let credential = ClientIdentityProvider.credential(for: identityID) {
                return (.useCredential, credential)
            }
            return (.performDefaultHandling, nil)
        default:
            return (.performDefaultHandling, nil)
        }
    }
}
