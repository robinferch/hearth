import Foundation
import HearthModel
import Synchronization
@testable import HearthAPI

enum Fixture {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name])
        }
        return try Data(contentsOf: url)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder.api.decode(T.self, from: data(name))
    }
}

/// A canned response for `MockURLProtocol`.
struct MockResponse: Sendable {
    var status: Int = 200
    var headers: [String: String] = [:]
    var body: Data = Data()
    var delay: Duration?
    var error: URLError?

    static func json(_ object: String, status: Int = 200) -> MockResponse {
        MockResponse(status: status, headers: ["Content-Type": "application/json"], body: Data(object.utf8))
    }

    static func fixture(_ name: String) -> MockResponse {
        MockResponse(status: 200, headers: ["Content-Type": "application/json"], body: (try? Fixture.data(name)) ?? Data())
    }

    static func status(_ status: Int) -> MockResponse {
        MockResponse(status: status)
    }
}

/// Recorded request including its body (URLSession moves bodies into a stream for protocols).
struct RecordedRequest: Sendable {
    var request: URLRequest
    var body: Data?

    var url: URL { request.url! }
    var path: String { request.url?.path() ?? "" }
    var method: String { request.httpMethod ?? "GET" }

    func header(_ name: String) -> String? {
        request.value(forHTTPHeaderField: name)
    }

    func query(_ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    var jsonBody: Any? {
        body.flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }
}

/// Routes requests by host to per-test handlers so tests can run in parallel.
///
/// `@unchecked Sendable`: URLProtocol instances are owned by the URL loading system and only touched from its
/// callbacks; the shared static state is guarded by `Mutex`. Needed to finish delayed responses off-thread.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (RecordedRequest) -> MockResponse

    private static let handlers = Mutex<[String: Handler]>([:])
    private static let recorded = Mutex<[String: [RecordedRequest]]>([:])

    /// Installs the mock for all new API sessions and returns a unique host.
    static func register(path: String = "", handler: @escaping Handler) -> URL {
        URLSessionFactory.protocolClassesOverride = [MockURLProtocol.self]
        let host = "t\(UUID().uuidString.prefix(8).lowercased()).hearth.test"
        handlers.withLock { $0[host] = handler }
        return URL(string: "https://\(host)\(path)")!
    }

    static func requests(for host: URL) -> [RecordedRequest] {
        recorded.withLock { $0[host.host() ?? ""] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host() else { return false }
        return handlers.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let host = request.url?.host() ?? ""
        let recordedRequest = RecordedRequest(request: request, body: Self.body(of: request))
        Self.recorded.withLock { $0[host, default: []].append(recordedRequest) }

        guard let handler = Self.handlers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let response = handler(recordedRequest)
        let client = client
        let url = request.url!

        let deliver: @Sendable () -> Void = { [self] in
            if let error = response.error {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
            let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        if let delay = response.delay {
            let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

actor MockTokenStore: TokenStore {
    private var storage: [ConnectionID: AuthTokens] = [:]
    private(set) var storeCount = 0

    init(_ tokens: AuthTokens? = nil, for connectionID: ConnectionID? = nil) {
        if let tokens, let connectionID {
            storage[connectionID] = tokens
        }
    }

    func tokens(for connectionID: ConnectionID) async -> AuthTokens? {
        storage[connectionID]
    }

    func store(_ tokens: AuthTokens, for connectionID: ConnectionID) async {
        storage[connectionID] = tokens
        storeCount += 1
    }

    func set(_ tokens: AuthTokens, for connectionID: ConnectionID) {
        storage[connectionID] = tokens
    }
}

final class MockDelegate: APIClientDelegate {
    private let calls = Mutex<[ConnectionID]>([])

    var unauthorizedConnections: [ConnectionID] { calls.withLock { $0 } }

    func apiClientDidBecomeUnauthorized(_ connectionID: ConnectionID) async {
        calls.withLock { $0.append(connectionID) }
    }
}

/// Builds a client against a mock host.
struct ClientHarness {
    let host: URL
    let connection: Connection
    let tokenStore: MockTokenStore
    let delegate: MockDelegate
    let client: APIClient

    init(path: String = "", tokens: AuthTokens? = AuthTokens(accessToken: "access-1", refreshToken: "refresh-1"), headers: [HTTPHeader] = [], handler: @escaping MockURLProtocol.Handler) {
        host = MockURLProtocol.register(path: path, handler: handler)
        connection = Connection(host: host, username: "robin", userID: "usr_1", headers: headers)
        tokenStore = MockTokenStore(tokens, for: connection.id)
        delegate = MockDelegate()
        var configuration = RequestExecutor.Configuration()
        configuration.retryDelay = .milliseconds(1)
        client = APIClient(connection: connection, tokenStore: tokenStore, delegate: delegate, configuration: configuration)
    }

    var requests: [RecordedRequest] { MockURLProtocol.requests(for: host) }
}

/// Thread-safe counter for handlers.
final class Counter: Sendable {
    private let value = Mutex(0)

    @discardableResult
    func increment() -> Int {
        value.withLock { value in
            value += 1
            return value
        }
    }

    var current: Int { value.withLock { $0 } }
}
