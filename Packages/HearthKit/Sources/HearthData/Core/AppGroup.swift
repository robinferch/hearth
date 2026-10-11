import Foundation

/// Shared container used by the app, widgets, intents and (on watchOS) complications.
public enum AppGroup {
    /// Read from the `HearthAppGroup` Info.plist key (set via build settings), with a fallback for tests.
    public static let identifier: String = {
        if let value = Bundle.main.object(forInfoDictionaryKey: "HearthAppGroup") as? String, !value.isEmpty {
            return value
        }
        return "group.me.robinferch.hearth"
    }()

    /// Keychain access group (`$(AppIdentifierPrefix)<bundle prefix>.Hearth`), from the `HearthKeychainGroup` Info.plist key.
    public static let keychainAccessGroup: String? = Bundle.main.object(forInfoDictionaryKey: "HearthKeychainGroup") as? String

    nonisolated(unsafe) public static let defaults: UserDefaults = UserDefaults(suiteName: identifier) ?? .standard

    /// Root of the shared container; falls back to Application Support when the group is unavailable (e.g. tests, free accounts).
    public static let containerURL: URL = {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            return url
        }
        let url = URL.applicationSupportDirectory.appending(path: "Hearth", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    public static func directory(_ name: String) -> URL {
        let url = containerURL.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var cachesURL: URL { directory("Library/Caches/Hearth") }
    public static var downloadsURL: URL { directory("Downloads") }
}
