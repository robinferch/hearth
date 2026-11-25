import Foundation

/// API keys the user enters (bring your own key). Stored in the Keychain on this device only (not synced).
public enum SecretStore {
    public enum Secret: String, Sendable {
        case anthropicAPIKey = "secret:anthropic-api-key"
    }

    private static let keychain = Keychain()

    public static func value(_ secret: Secret) -> String? {
        keychain.data(account: secret.rawValue).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Stores (or, for an empty value, deletes) a secret.
    public static func set(_ value: String?, for secret: Secret) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            keychain.delete(account: secret.rawValue)
        } else {
            keychain.set(Data(trimmed.utf8), account: secret.rawValue, synchronizable: false)
        }
    }

    public static func has(_ secret: Secret) -> Bool {
        value(secret) != nil
    }
}
