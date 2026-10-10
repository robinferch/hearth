import Foundation
import HearthAPI
import HearthData
import HearthPlayback
import Observation

/// A warning / confirmation alert with arbitrary actions.
struct WarningAlert: Identifiable {
    struct Action: Identifiable {
        enum Role {
            case normal
            case destructive
            case cancel
        }

        let id = UUID()
        var title: String
        var role: Role = .normal
        var perform: @MainActor () async -> Void = {}
    }

    let id = UUID()
    var title: String
    var message: String?
    var actions: [Action]
}

/// Scene-wide alert and haptic feedback coordinator.
@MainActor
@Observable
final class AlertCenter {
    var alert: WarningAlert?

    /// Incremented to trigger success / error haptics (`.sensoryFeedback`).
    private(set) var successTrigger = 0
    private(set) var errorTrigger = 0

    func present(_ alert: WarningAlert) {
        self.alert = alert
    }

    func succeed() {
        successTrigger += 1
    }

    func fail(_ error: any Error, title: String? = nil) {
        errorTrigger += 1
        alert = WarningAlert(
            title: title ?? String(localized: "Something went wrong"),
            message: error.userMessage,
            actions: [WarningAlert.Action(title: String(localized: "OK"), role: .cancel)]
        )
    }
}

extension Error {
    /// Localized, user-facing description for errors from the Hearth modules.
    var userMessage: String {
        if let error = self as? APIError {
            return switch error {
            case .offline: String(localized: "Hearth is in offline mode.")
            case .unreachable: String(localized: "The server can't be reached. Check the address and your network connection.")
            case .unauthorized: String(localized: "Your session expired. Please sign in again.")
            case .notFound: String(localized: "The item could not be found on the server.")
            case .invalidURL: String(localized: "The server address is invalid.")
            case .invalidResponse(let statusCode): String(localized: "The server responded with an unexpected status (\(statusCode)).")
            case .decoding: String(localized: "The server's response could not be read.")
            case .transport(let message): message
            case .cancelled: String(localized: "The request was cancelled.")
            case .serverNotInitialized: String(localized: "This audiobookshelf server has not been set up yet.")
            case .unsupportedAuthMethod: String(localized: "This sign-in method is not supported by the server.")
            case .untrustedCertificate: String(localized: "The server's certificate is not trusted.")
            }
        }
        if let error = self as? DownloadError {
            return switch error {
            case .itemIsPlaying: String(localized: "The item is currently playing.")
            case .itemIsDownloading: String(localized: "The item is currently downloading.")
            case .notDownloadable: String(localized: "This item can't be downloaded.")
            case .cellularNotAllowed: String(localized: "Downloads over cellular are turned off in Settings.")
            }
        }
        if let error = self as? PlaybackError {
            return switch error {
            case .notPlayable: String(localized: "This item can't be played.")
            case .downloadInProgress: String(localized: "The item is currently downloading.")
            case .noPlaybackItem: String(localized: "Nothing is playing.")
            case .startFailed(let message): message
            }
        }
        return localizedDescription
    }
}
