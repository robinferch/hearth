import Foundation
import HearthModel
import os

/// Minimal Socket.IO v4 client (Engine.IO v4, WebSocket transport only) for audiobookshelf live updates.
///
/// After the namespace connect it emits `auth` with the access token. The connection is re-established with
/// exponential backoff until `disconnect()` is called. A watchdog reconnects when the server stops pinging.
actor SocketIOClient {
    enum Event: Sendable {
        case connected
        case disconnected
        /// A server event and its first argument as JSON (if any).
        case event(name: String, payload: Data?)
    }

    struct Configuration: Sendable {
        var host: URL
        var headers: [HTTPHeader]
        var pinnedSHA256: String?
        var identityID: ConnectionID
        var maxBackoff: Duration = .seconds(60)
    }

    private let configuration: Configuration
    private let session: URLSession
    private let tokenProvider: @Sendable () async -> String?
    private let authFailed: @Sendable (_ token: String?) async -> Void
    private let handler: @Sendable (Event) async -> Void
    private let logger = Logger.api(SocketIOClient.self)

    private var wantsConnection = false
    private var generation = 0
    private var task: URLSessionWebSocketTask?
    private var token: String?
    private var isConnected = false
    private var reconnectAttempt = 0
    private var lastActivity = ContinuousClock.now
    private var receiveTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    init(
        configuration: Configuration,
        session: URLSession,
        tokenProvider: @escaping @Sendable () async -> String?,
        authFailed: @escaping @Sendable (_ token: String?) async -> Void,
        handler: @escaping @Sendable (Event) async -> Void
    ) {
        self.configuration = configuration
        self.session = session
        self.tokenProvider = tokenProvider
        self.authFailed = authFailed
        self.handler = handler
    }

    var connected: Bool { isConnected }

    func connect() async {
        wantsConnection = true
        guard task == nil, reconnectTask == nil else { return }
        await open()
    }

    func disconnect() async {
        wantsConnection = false
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        await teardown()
    }

    // MARK: Connection lifecycle

    private func open() async {
        generation += 1
        let generation = generation
        let token = await tokenProvider()
        guard wantsConnection, generation == self.generation, task == nil else { return }

        let url: URL
        do {
            url = try URLBuilder.socketURL(host: configuration.host)
        } catch {
            logger.error("Invalid socket URL for \(self.configuration.host.absoluteString, privacy: .private)")
            return
        }

        var request = URLRequest(url: url, timeoutInterval: 45)
        request.applyHeaders(connectionHeaders: configuration.headers, accessToken: token)

        let task = session.webSocketTask(with: request)
        task.delegate = TaskSecurityDelegate(pinnedSHA256: configuration.pinnedSHA256, identityID: configuration.identityID)
        self.task = task
        self.token = token
        lastActivity = .now
        task.resume()
        logger.debug("Socket connecting")

        receiveTask = Task { [weak self] in
            await self?.receiveLoop(task: task, generation: generation)
        }
    }

    private func receiveLoop(task: URLSessionWebSocketTask, generation: Int) async {
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                guard generation == self.generation else { return }
                logger.info("Socket receive failed: \(error.localizedDescription, privacy: .public)")
                await connectionLost(generation: generation)
                return
            }
            guard generation == self.generation else { return }

            switch message {
            case .string(let text):
                await handle(text, generation: generation)
            case .data(let data):
                await handle(String(decoding: data, as: UTF8.self), generation: generation)
            @unknown default:
                break
            }
        }
    }

    private func handle(_ text: String, generation: Int) async {
        lastActivity = .now
        guard let packet = EnginePacket.parse(text) else {
            logger.debug("Ignoring malformed socket frame")
            return
        }

        switch packet {
        case .open(let handshake):
            startWatchdog(handshake: handshake, generation: generation)
            await send(EnginePacket.message(.connect(sid: nil)).encoded)
        case .ping(let data):
            await send(EnginePacket.pong(data).encoded)
        case .message(.connect):
            await send(EnginePacket.message(.event("auth", strings: [token ?? ""])).encoded)
            isConnected = true
            reconnectAttempt = 0
            logger.info("Socket connected")
            await handler(.connected)
        case .message(.event(let name, let arguments, _)):
            if name == "auth_failed" {
                logger.error("Socket authentication failed")
                await authFailed(token)
                await connectionLost(generation: generation)
                return
            }
            await handler(.event(name: name, payload: arguments.first))
        case .message(.disconnect), .message(.connectError), .close:
            await connectionLost(generation: generation)
        case .pong, .message(.ack), .upgrade, .noop:
            break
        }
    }

    private func send(_ text: String) async {
        guard let task else { return }
        do {
            try await task.send(.string(text))
        } catch {
            logger.debug("Socket send failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startWatchdog(handshake: EnginePacket.Handshake, generation: Int) {
        watchdogTask?.cancel()
        let limit = handshake.pingInterval + handshake.pingTimeout
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: limit)
                } catch {
                    return
                }
                guard let self else { return }
                if await self.isStale(limit: limit, generation: generation) {
                    await self.connectionLost(generation: generation)
                    return
                }
            }
        }
    }

    private func isStale(limit: Duration, generation: Int) -> Bool {
        generation == self.generation && ContinuousClock.now - lastActivity > limit
    }

    private func connectionLost(generation: Int) async {
        guard generation == self.generation else { return }
        await teardown()
        guard wantsConnection else { return }
        scheduleReconnect()
    }

    private func teardown() async {
        generation += 1
        receiveTask?.cancel()
        receiveTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        if isConnected {
            isConnected = false
            logger.info("Socket disconnected")
            await handler(.disconnected)
        }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectAttempt += 1
        let delay = Self.backoff(attempt: reconnectAttempt, maximum: configuration.maxBackoff)
        reconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await self?.reconnect()
        }
    }

    private func reconnect() async {
        reconnectTask = nil
        guard wantsConnection, task == nil else { return }
        await open()
    }

    /// 1 s, 2 s, 4 s … capped at `maximum`, with up to 20 % jitter.
    static func backoff(attempt: Int, maximum: Duration) -> Duration {
        let base = Duration.seconds(1 << min(max(attempt - 1, 0), 10))
        let capped = min(base, maximum)
        return capped + capped * Double.random(in: 0 ... 0.2)
    }
}
