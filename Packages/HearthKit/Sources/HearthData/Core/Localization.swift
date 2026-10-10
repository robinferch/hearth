import Foundation

extension DownloadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .itemIsPlaying:
            String(localized: "download.error.playing", defaultValue: "This item is currently playing.", bundle: .module)
        case .itemIsDownloading:
            String(localized: "download.error.downloading", defaultValue: "This item is still downloading.", bundle: .module)
        case .notDownloadable:
            String(localized: "download.error.notDownloadable", defaultValue: "This item can't be downloaded.", bundle: .module)
        case .cellularNotAllowed:
            String(localized: "download.error.cellular", defaultValue: "Downloads over cellular are turned off.", bundle: .module)
        }
    }
}

extension ClientCertificateError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidPassphrase:
            String(localized: "certificate.error.passphrase", defaultValue: "The password for the certificate is incorrect.", bundle: .module)
        case .noIdentity:
            String(localized: "certificate.error.noIdentity", defaultValue: "The file doesn't contain a certificate with a private key.", bundle: .module)
        case .importFailed:
            String(localized: "certificate.error.importFailed", defaultValue: "The certificate couldn't be imported.", bundle: .module)
        }
    }
}

public extension OfflineReason {
    /// Short explanation shown in the offline view / library picker.
    var localizedDescription: String {
        switch self {
        case .user:
            String(localized: "offline.reason.user", defaultValue: "Offline mode is turned on.", bundle: .module)
        case .noNetwork:
            String(localized: "offline.reason.noNetwork", defaultValue: "No internet connection.", bundle: .module)
        case .unreachable:
            String(localized: "offline.reason.unreachable", defaultValue: "None of your servers can be reached.", bundle: .module)
        }
    }
}

public extension ConnectionStatus {
    var localizedDescription: String {
        switch self {
        case .loading:
            String(localized: "connection.status.loading", defaultValue: "Connecting…", bundle: .module)
        case .online:
            String(localized: "connection.status.online", defaultValue: "Online", bundle: .module)
        case .offline:
            String(localized: "connection.status.offline", defaultValue: "Offline", bundle: .module)
        case .unauthorized:
            String(localized: "connection.status.unauthorized", defaultValue: "Sign in again", bundle: .module)
        }
    }
}
