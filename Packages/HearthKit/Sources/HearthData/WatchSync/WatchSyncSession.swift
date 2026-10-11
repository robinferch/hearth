import Foundation
import Observation
import os

#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

public enum WatchSyncError: Error, Sendable {
    /// WatchConnectivity isn't available on this device.
    case unsupported
    /// The counterpart app isn't reachable right now (not running / out of range).
    case notReachable
    /// The counterpart replied with something unexpected.
    case invalidReply
    case transport(String)
}

/// Thin async wrapper around `WCSession`, shared by the iPhone app (`WatchBridge`) and the watch app.
///
/// - Incoming messages, user info and application contexts are decoded into `WatchSyncMessage` and handed to
///   `messageHandler`, whose return value is sent back as the reply (for `send(_:)`).
/// - Messages arriving before a handler is installed are buffered and delivered once it is set.
@MainActor
@Observable
public final class WatchSyncSession {
    public static let shared = WatchSyncSession()

    public enum Activation: Sendable {
        case notActivated
        case inactive
        case activated
    }

    public private(set) var activation: Activation = .notActivated
    /// Whether the counterpart app can receive live messages (`sendMessage`).
    public private(set) var isReachable = false
    #if os(iOS)
    public private(set) var isPaired = false
    public private(set) var isWatchAppInstalled = false
    public private(set) var isComplicationEnabled = false
    #endif
    #if os(watchOS)
    public private(set) var isCompanionAppInstalled = false
    #endif

    /// The last application context received from the counterpart.
    public private(set) var receivedContext: WatchSyncMessage?

    /// Handles incoming messages. The return value is the reply for messages that expect one.
    @ObservationIgnored public var messageHandler: (@MainActor (WatchSyncMessage) async -> WatchSyncMessage?)? {
        didSet { flushPending() }
    }

    /// Called when reachability or activation changes.
    @ObservationIgnored public var stateHandler: (@MainActor () -> Void)?

    @ObservationIgnored private var pending: [WatchSyncMessage] = []
    @ObservationIgnored private let logger = Logger(category: "WatchSyncSession")

    #if canImport(WatchConnectivity)
    @ObservationIgnored private var delegate: SessionDelegate?
    #endif

    init() {}

    /// Whether WatchConnectivity can be used on this device.
    public var isSupported: Bool {
        #if canImport(WatchConnectivity)
        WCSession.isSupported()
        #else
        false
        #endif
    }

    // MARK: Activation

    /// Activates the session (idempotent).
    public func activate() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported(), delegate == nil else { return }
        let delegate = SessionDelegate(owner: self)
        self.delegate = delegate
        let session = WCSession.default
        session.delegate = delegate
        session.activate()
        #endif
    }

    /// Waits until the session is activated (returns immediately when unsupported or already active).
    public func waitUntilActivated(timeout: Duration = .seconds(5)) async {
        guard isSupported else { return }
        activate()
        let deadline = ContinuousClock.now + timeout
        while activation != .activated, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: Sending

    /// Sends a live message and waits for the reply. Requires the counterpart to be reachable.
    public func send(_ message: WatchSyncMessage) async throws -> WatchSyncMessage {
        #if canImport(WatchConnectivity)
        guard isSupported else { throw WatchSyncError.unsupported }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { throw WatchSyncError.notReachable }
        let payload = try message.dictionary()
        return try await withCheckedThrowingContinuation { continuation in
            session.sendMessage(payload, replyHandler: { reply in
                if let message = WatchSyncMessage(dictionary: reply) {
                    continuation.resume(returning: message)
                } else {
                    continuation.resume(throwing: WatchSyncError.invalidReply)
                }
            }, errorHandler: { error in
                continuation.resume(throwing: WatchSyncError.transport(error.localizedDescription))
            })
        }
        #else
        throw WatchSyncError.unsupported
        #endif
    }

    /// Sends a live message without waiting for a reply; silently dropped when not reachable.
    public func sendIfReachable(_ message: WatchSyncMessage) {
        #if canImport(WatchConnectivity)
        guard isSupported else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable, let payload = try? message.dictionary() else { return }
        let logger = logger
        session.sendMessage(payload, replyHandler: nil) { error in
            logger.debug("Sending a message failed: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    /// Queues a message for guaranteed, in-order delivery (also while the counterpart isn't running).
    public func transfer(_ message: WatchSyncMessage) {
        #if canImport(WatchConnectivity)
        guard isSupported, WCSession.default.activationState == .activated, let payload = try? message.dictionary() else { return }
        WCSession.default.transferUserInfo(payload)
        #endif
    }

    /// Replaces the application context (latest state wins).
    public func updateApplicationContext(_ message: WatchSyncMessage) {
        #if canImport(WatchConnectivity)
        guard isSupported, WCSession.default.activationState == .activated else { return }
        do {
            try WCSession.default.updateApplicationContext(try message.dictionary())
        } catch {
            logger.debug("Updating the application context failed: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    #if os(iOS) && canImport(WatchConnectivity)
    /// Remaining complication transfers today (`transferCurrentComplicationUserInfo` budget).
    public var remainingComplicationTransfers: Int {
        guard isSupported, WCSession.default.activationState == .activated else { return 0 }
        return WCSession.default.remainingComplicationUserInfoTransfers
    }

    /// Sends a high-priority update for the watch complications. Returns `false` when no complication is active
    /// or the daily budget is used up (fall back to the application context).
    @discardableResult
    public func transferComplicationInfo(_ message: WatchSyncMessage) -> Bool {
        let session = WCSession.default
        guard isSupported, session.activationState == .activated, session.isComplicationEnabled,
              session.remainingComplicationUserInfoTransfers > 0, let payload = try? message.dictionary() else {
            return false
        }
        session.transferCurrentComplicationUserInfo(payload)
        return true
    }
    #endif

    // MARK: Receiving (called by the delegate on the main actor)

    fileprivate func refreshState() {
        #if canImport(WatchConnectivity)
        let session = WCSession.default
        activation = switch session.activationState {
        case .activated: .activated
        case .inactive: .inactive
        default: .notActivated
        }
        isReachable = session.activationState == .activated && session.isReachable
        #if os(iOS)
        isPaired = session.isPaired
        isWatchAppInstalled = session.isWatchAppInstalled
        isComplicationEnabled = session.isComplicationEnabled
        #elseif os(watchOS)
        isCompanionAppInstalled = session.isCompanionAppInstalled
        #endif
        if activation == .activated {
            if receivedContext == nil, let context = WatchSyncMessage(dictionary: session.receivedApplicationContext) {
                receive(context, isContext: true)
            }
        }
        #endif
        stateHandler?()
    }

    fileprivate func receive(_ message: WatchSyncMessage, isContext: Bool) {
        if isContext {
            receivedContext = message
        }
        guard let messageHandler else {
            pending.append(message)
            return
        }
        Task {
            _ = await messageHandler(message)
        }
    }

    fileprivate func receive(_ message: WatchSyncMessage, reply: @escaping @Sendable (WatchSyncMessage) -> Void) {
        guard let messageHandler else {
            // Nobody is listening yet: acknowledge so the sender doesn't wait for a timeout.
            pending.append(message)
            reply(.acknowledged)
            return
        }
        Task {
            let response = await messageHandler(message) ?? .acknowledged
            reply(response)
        }
    }

    private func flushPending() {
        guard let messageHandler, !pending.isEmpty else { return }
        let messages = pending
        pending.removeAll()
        Task {
            for message in messages {
                _ = await messageHandler(message)
            }
        }
    }
}

#if canImport(WatchConnectivity)

/// `WCSessionDelegate` bridge. Callbacks arrive on a background queue; payloads are decoded there and the
/// (Sendable) messages are forwarded to the main actor.
private final class SessionDelegate: NSObject, WCSessionDelegate, @unchecked Sendable {
    private weak var owner: WatchSyncSession?

    init(owner: WatchSyncSession) {
        self.owner = owner
    }

    private func refresh() {
        Task { @MainActor [weak owner] in
            owner?.refreshState()
        }
    }

    private func deliver(_ payload: [String: Any], isContext: Bool) {
        guard let message = WatchSyncMessage(dictionary: payload) else { return }
        Task { @MainActor [weak owner] in
            owner?.receive(message, isContext: isContext)
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        refresh()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        refresh()
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {
        refresh()
    }

    func sessionDidDeactivate(_ session: WCSession) {
        // Switching watches: activate again for the new one.
        session.activate()
        refresh()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        refresh()
    }
    #endif

    #if os(watchOS)
    func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
        refresh()
    }
    #endif

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        deliver(message, isContext: false)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let decoded = WatchSyncMessage(dictionary: message) else {
            replyHandler([:])
            return
        }
        nonisolated(unsafe) let replyHandler = replyHandler
        let reply: @Sendable (WatchSyncMessage) -> Void = { response in
            replyHandler((try? response.dictionary()) ?? [:])
        }
        Task { @MainActor [weak owner] in
            if let owner {
                owner.receive(decoded, reply: reply)
            } else {
                reply(.acknowledged)
            }
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        deliver(userInfo, isContext: false)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        deliver(applicationContext, isContext: true)
    }
}

#endif
