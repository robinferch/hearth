import Foundation
import os
import Security
import Synchronization

/// Thin generic-password Keychain wrapper.
///
/// Items are accessible after first unlock (background refresh, CarPlay, watch). The shared access group is used
/// when the entitlement is present; when it isn't (unsigned simulator builds, `swift test`) the wrapper falls back
/// to the default group and remembers that decision.
struct Keychain: Sendable {
    let service: String
    let accessGroup: String?

    private static let logger = Logger(category: "Keychain")
    /// `nil` = undecided, `true` = access group works, `false` = fall back to the default group.
    private static let groupUsable = Mutex<Bool?>(nil)

    init(service: String = "me.robinferch.hearth.credentials", accessGroup: String? = AppGroup.keychainAccessGroup) {
        self.service = service
        // Unresolved build settings (e.g. `$(AppIdentifierPrefix)` in unsigned builds) can't be valid groups.
        if let accessGroup, !accessGroup.isEmpty, !accessGroup.contains("$("), !accessGroup.hasPrefix(".") {
            self.accessGroup = accessGroup
        } else {
            self.accessGroup = nil
        }
    }

    private func baseQuery(account: String?, synchronizable: Bool?, useGroup: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        if let synchronizable {
            query[kSecAttrSynchronizable as String] = synchronizable ? kCFBooleanTrue : kCFBooleanFalse
        } else {
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        }
        if useGroup, let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private static func isEntitlementFailure(_ status: OSStatus) -> Bool {
        status == errSecMissingEntitlement || status == errSecNoAccessForItem || status == errSecParam
    }

    /// Runs `operation` with the access group if usable, falling back to the default group on entitlement errors.
    private func withGroupFallback(_ operation: (_ useGroup: Bool) -> OSStatus) -> OSStatus {
        guard accessGroup != nil else { return operation(false) }
        let decision = Self.groupUsable.withLock { $0 }
        if decision == false {
            return operation(false)
        }
        let status = operation(true)
        if Self.isEntitlementFailure(status) {
            Self.logger.notice("Keychain access group unavailable (\(status)); using the default group")
            Self.groupUsable.withLock { $0 = false }
            return operation(false)
        }
        if decision == nil, status == errSecSuccess || status == errSecItemNotFound || status == errSecDuplicateItem {
            Self.groupUsable.withLock { $0 = true }
        }
        return status
    }

    func data(account: String) -> Data? {
        var result: AnyObject?
        let status = withGroupFallback { useGroup in
            var query = baseQuery(account: account, synchronizable: nil, useGroup: useGroup)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            return SecItemCopyMatching(query as CFDictionary, &result)
        }
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                Self.logger.error("Reading \(account, privacy: .public) failed: \(status)")
            }
            return nil
        }
        return result as? Data
    }

    /// Writes `data`. The existing item is updated in place (or added if missing), so a failed write keeps the
    /// previous value instead of losing it (e.g. rotated tokens).
    @discardableResult
    func set(_ data: Data, account: String, synchronizable: Bool) -> Bool {
        var status = withGroupFallback { useGroup in
            let query = baseQuery(account: account, synchronizable: synchronizable, useGroup: useGroup)
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            return SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        }
        if status == errSecItemNotFound {
            status = withGroupFallback { useGroup in
                var query = baseQuery(account: account, synchronizable: synchronizable, useGroup: useGroup)
                query[kSecValueData as String] = data
                query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                return SecItemAdd(query as CFDictionary, nil)
            }
        }
        guard status == errSecSuccess else {
            Self.logger.error("Writing \(account, privacy: .public) failed: \(status)")
            return false
        }
        // A copy with the other synchronizable flag (the flag can't be changed in place) is obsolete now.
        _ = withGroupFallback { useGroup in
            SecItemDelete(baseQuery(account: account, synchronizable: !synchronizable, useGroup: useGroup) as CFDictionary)
        }
        return true
    }

    func delete(account: String) {
        _ = withGroupFallback { useGroup in
            SecItemDelete(baseQuery(account: account, synchronizable: nil, useGroup: useGroup) as CFDictionary)
        }
    }

    /// All `(account, data)` pairs whose account starts with `prefix`.
    func items(prefix: String) -> [(account: String, data: Data)] {
        var result: AnyObject?
        let status = withGroupFallback { useGroup in
            var query = baseQuery(account: nil, synchronizable: nil, useGroup: useGroup)
            query[kSecReturnData as String] = true
            query[kSecReturnAttributes as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitAll
            return SecItemCopyMatching(query as CFDictionary, &result)
        }
        guard status == errSecSuccess, let entries = result as? [[String: Any]] else {
            if status != errSecItemNotFound {
                Self.logger.error("Listing items failed: \(status)")
            }
            return []
        }
        return entries.compactMap { entry in
            guard let account = entry[kSecAttrAccount as String] as? String, account.hasPrefix(prefix), let data = entry[kSecValueData as String] as? Data else {
                return nil
            }
            return (account, data)
        }
    }
}
