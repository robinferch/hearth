import Foundation
import Synchronization

/// Fans out values to any number of `AsyncStream` subscribers.
final class EventBroadcaster<Element: Sendable>: Sendable {
    private let continuations = Mutex<[UUID: AsyncStream<Element>.Continuation]>([:])

    /// A new stream receiving every value yielded after this call. Ends when the subscriber stops iterating.
    func stream(bufferingNewest limit: Int = 64) -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream<Element>.makeStream(bufferingPolicy: .bufferingNewest(limit))
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            self?.continuations.withLock { _ = $0.removeValue(forKey: id) }
        }
        continuations.withLock { $0[id] = continuation }
        return stream
    }

    func yield(_ value: Element) {
        let current = continuations.withLock { Array($0.values) }
        for continuation in current {
            continuation.yield(value)
        }
    }

    var subscriberCount: Int {
        continuations.withLock { $0.count }
    }

    func finish() {
        let current = continuations.withLock { continuations in
            defer { continuations.removeAll() }
            return Array(continuations.values)
        }
        for continuation in current {
            continuation.finish()
        }
    }
}
