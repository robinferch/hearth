import Foundation
import os

extension Logger {
    /// Subsystem shared by all HearthAPI loggers (the host app's bundle id).
    static let hearthSubsystem = Bundle.main.bundleIdentifier ?? "dev.hearth"

    /// Creates a logger whose category is the given type's name.
    static func api(_ type: Any.Type) -> Logger {
        Logger(subsystem: hearthSubsystem, category: String(describing: type))
    }
}
