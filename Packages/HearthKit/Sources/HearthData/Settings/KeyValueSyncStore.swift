import Foundation
import Synchronization

/// Small string key/value store synced across devices (iCloud KVS) with a local fallback.
protocol KeyValueSyncStore: Sendable {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
    /// Posted (on any thread) when values changed on another device.
    var externalChangeNotification: Notification.Name? { get }
    func synchronize()
}

/// `NSUbiquitousKeyValueStore` backed store. Every write also goes to the local defaults so values survive when
/// iCloud is unavailable (no account, missing entitlement in `Basic` builds, …); reads prefer iCloud.
final class UbiquitousKeyValueStore: KeyValueSyncStore, @unchecked Sendable {
    private let fallback: UserDefaults
    private let prefix = "kvs."

    init(fallback: UserDefaults) {
        self.fallback = fallback
    }

    private var cloud: NSUbiquitousKeyValueStore { .default }

    func string(forKey key: String) -> String? {
        cloud.string(forKey: key) ?? fallback.string(forKey: prefix + key)
    }

    func set(_ value: String?, forKey key: String) {
        if let value {
            cloud.set(value, forKey: key)
            fallback.set(value, forKey: prefix + key)
        } else {
            cloud.removeObject(forKey: key)
            fallback.removeObject(forKey: prefix + key)
        }
    }

    var externalChangeNotification: Notification.Name? {
        NSUbiquitousKeyValueStore.didChangeExternallyNotification
    }

    func synchronize() {
        cloud.synchronize()
    }
}

final class InMemoryKeyValueStore: KeyValueSyncStore {
    private let values = Mutex<[String: String]>([:])

    func string(forKey key: String) -> String? { values.withLock { $0[key] } }
    func set(_ value: String?, forKey key: String) { values.withLock { $0[key] = value } }
    var externalChangeNotification: Notification.Name? { nil }
    func synchronize() {}
}
