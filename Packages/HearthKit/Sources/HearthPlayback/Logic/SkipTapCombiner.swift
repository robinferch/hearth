import Foundation

/// Combines rapid skip-button taps into a single seek.
///
/// The first tap opens a 0.3 s window; every further tap inside the window adds its amount and
/// extends the window by 0.7 s. When the window closes, the accumulated total is applied once.
public struct SkipTapCombiner: Sendable, Hashable {
    public static let firstWindow: TimeInterval = 0.3
    public static let followUpWindow: TimeInterval = 0.7

    /// Accumulated signed seconds (negative = backwards).
    public private(set) var total: TimeInterval = 0
    public private(set) var tapCount = 0
    public private(set) var deadline: Date?

    public init() {}

    public var isPending: Bool { deadline != nil }

    /// Registers a tap (signed amount) and returns the new deadline. Taps in both directions are summed.
    @discardableResult
    public mutating func registerTap(amount: TimeInterval, at now: Date) -> Date {
        if let deadline, deadline > now {
            total += amount
            tapCount += 1
            self.deadline = now.addingTimeInterval(Self.followUpWindow)
        } else {
            total = amount
            tapCount = 1
            deadline = now.addingTimeInterval(Self.firstWindow)
        }
        return deadline ?? now
    }

    /// Returns and clears the accumulated total once the window has closed.
    public mutating func flush(at now: Date) -> TimeInterval? {
        guard let deadline, now >= deadline else { return nil }
        let result = total
        reset()
        return result
    }

    public mutating func reset() {
        total = 0
        tapCount = 0
        deadline = nil
    }
}
