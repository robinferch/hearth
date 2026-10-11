import AppIntents
import Foundation
import HearthData
import HearthModel
import os

// Localization note
// -----------------
// App Intents metadata (titles, parameter names, type names, enum cases) is extracted at build time and resolved
// by the system against the bundle that hosts the metadata (the app and the widget extension), not against this
// package's resource bundle. All strings of this module therefore live in the `System` table
// (`App/Resources/iOS/System.xcstrings`), which is bundled into both the app and the widget extension.
// Runtime strings use `String(localized:table: "System")` against `Bundle.main` for the same reason.

/// Registers this module's intents, entities and queries with the App Intents metadata of the consuming targets.
/// The app and the widget extension each declare an `AppIntentsPackage` that lists this package.
public struct HearthIntentsPackage: AppIntentsPackage {}

/// Navigation requests from intents that open the app (open item, search). The app installs a handler at launch.
@MainActor
public enum IntentNavigator {
    public enum Route: Hashable, Sendable {
        case open(ItemIdentifier)
        case search(String?)
    }

    /// Set by the app; called on the main actor when an intent wants to navigate.
    public static var handler: ((Route) -> Void)?

    /// Requests that arrived before the app installed its handler.
    static var pending: Route?

    static func navigate(_ route: Route) {
        if let handler {
            handler(route)
        } else {
            pending = route
        }
    }

    /// Returns and clears a request that arrived before `handler` was set.
    public static func consumePending() -> Route? {
        defer { pending = nil }
        return pending
    }
}

/// Errors surfaced to Siri / Shortcuts.
public enum HearthIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notSignedIn
    case itemNotFound
    case notPlayable
    case nothingPlaying
    case noChapters
    case noSleepTimer
    case bookmarksUnsupported
    case failed(String)

    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notSignedIn: LocalizedStringResource("Sign in to an audiobookshelf server in Hearth first.", table: "System")
        case .itemNotFound: LocalizedStringResource("The item couldn't be found.", table: "System")
        case .notPlayable: LocalizedStringResource("This item can't be played.", table: "System")
        case .nothingPlaying: LocalizedStringResource("Nothing is playing.", table: "System")
        case .noChapters: LocalizedStringResource("The current item has no chapters.", table: "System")
        case .noSleepTimer: LocalizedStringResource("No sleep timer is active.", table: "System")
        case .bookmarksUnsupported: LocalizedStringResource("Bookmarks are only available for audiobooks.", table: "System")
        case .failed(let message): LocalizedStringResource(stringLiteral: message)
        }
    }
}

/// Shared helpers for intent implementations.
enum IntentSupport {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.robinferch.hearth", category: "Intents")

    /// `true` inside the widget extension (no audio session, no player).
    static var isExtension: Bool {
        Bundle.main.bundleURL.pathExtension == "appex"
    }

    /// Localized runtime string from the `System` table of the host bundle.
    static func text(_ key: String.LocalizationValue) -> String {
        String(localized: key, table: "System")
    }

    /// A dialog from an already localized string.
    static func dialog(_ text: String) -> IntentDialog {
        IntentDialog(LocalizedStringResource(stringLiteral: text))
    }

    /// Makes sure the data layer and the player are ready when an intent launches the app in the background.
    @MainActor
    static func prepare() throws {
        let data = HearthData.shared
        guard !data.connections.connections.isEmpty else { throw HearthIntentError.notSignedIn }
    }

    @MainActor
    static func identifier(_ string: String) throws -> ItemIdentifier {
        guard let id = ItemIdentifier(string) else { throw HearthIntentError.itemNotFound }
        return id
    }

    /// Maps lower-level errors to a message Siri can speak.
    static func wrap(_ error: any Error) -> any Error {
        if error is HearthIntentError {
            return error
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return HearthIntentError.failed(description)
        }
        return HearthIntentError.failed(error.localizedDescription)
    }
}
