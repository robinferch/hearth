import Foundation
import Network

struct NetworkState: Sendable, Equatable {
    var isSatisfied: Bool
    var isExpensive: Bool
    var isConstrained: Bool
}

/// Wraps `NWPathMonitor` and delivers path changes on the main actor.
final class NetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "me.robinferch.hearth.network-monitor", qos: .utility)

    func start(_ handler: @escaping @MainActor @Sendable (NetworkState) -> Void) {
        monitor.pathUpdateHandler = { path in
            let state = NetworkState(isSatisfied: path.status == .satisfied, isExpensive: path.isExpensive, isConstrained: path.isConstrained)
            Task { @MainActor in
                handler(state)
            }
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }
}
