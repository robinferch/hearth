import Foundation

/// Asks the system not to suspend the process until `end()` (or until it runs out of background time).
///
/// Used around token refreshes: the server rotates the refresh token as soon as it handles the request, so a
/// response lost because the app was suspended mid-request would leave only an invalidated refresh token behind.
/// Works in apps and extensions on iOS and watchOS (`ProcessInfo.performExpiringActivity`); a no-op on macOS (tests).
final class ExpiringActivity: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    init(reason: String) {
        #if os(iOS) || os(watchOS) || os(visionOS)
        let semaphore = semaphore
        // The block runs on a background queue and holds the assertion while it blocks. When the system needs the
        // process to suspend, it calls the block a second time with `expired == true`: release the first one.
        ProcessInfo.processInfo.performExpiringActivity(withReason: reason) { expired in
            if expired {
                semaphore.signal()
            } else {
                _ = semaphore.wait(timeout: .now() + 60)
            }
        }
        #endif
    }

    func end() {
        semaphore.signal()
    }
}
