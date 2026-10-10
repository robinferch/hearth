import Foundation
import SwiftUI

/// Shared SwiftUI building blocks used by the iOS app, widgets and the watch app.
///
/// All user-visible strings in this module are looked up in the module's own String Catalog
/// (`Resources/Localizable.xcstrings`). Use `HearthUI.localized(_:)` or `Text(_:bundle: .module)`.
public enum HearthUI {
    /// The bundle containing HearthUI's resources.
    public static var bundle: Bundle { .module }

    /// Looks up a string in HearthUI's String Catalog.
    public static func localized(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .module)
    }
}

/// Module-internal shorthand for `HearthUI.localized(_:)`.
func loc(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}
