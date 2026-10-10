import Foundation

public enum ImageSize: Int, Codable, Sendable, CaseIterable, Comparable {
    case tiny = 220
    case small = 320
    case regular = 600
    case large = 1000

    public var width: Int { rawValue }

    public static func < (lhs: ImageSize, rhs: ImageSize) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public extension TimeInterval {
    /// `1:02:03` / `2:03`.
    var clockFormatted: String {
        guard isFinite else { return "--:--" }
        let total = Int(self.rounded(.down))
        let hours = abs(total) / 3600
        let minutes = (abs(total) % 3600) / 60
        let seconds = abs(total) % 60
        let sign = total < 0 ? "-" : ""
        if hours > 0 {
            return String(format: "%@%d:%02d:%02d", sign, hours, minutes, seconds)
        }
        return String(format: "%@%d:%02d", sign, minutes, seconds)
    }

    /// `5h 12m` style, localised.
    var durationFormatted: String {
        guard isFinite, self > 0 else { return "" }
        let style = Duration.UnitsFormatStyle(allowedUnits: self >= 3600 ? [.hours, .minutes] : [.minutes, .seconds], width: .narrow, maximumUnitCount: 2)
        return Duration.seconds(self).formatted(style)
    }
}
