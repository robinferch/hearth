import Foundation
import HearthAPI
@testable import HearthData
import HearthModel
import Testing

/// iPhone and watch share one audiobookshelf session whose refresh token rotates on every refresh.
@Suite("Shared session with the paired device")
@MainActor
struct PairedSessionTests {
    /// A token pair whose refresh token the server issued `age` seconds ago.
    static func tokens(_ name: String, issuedAgo age: TimeInterval) -> AuthTokens {
        func encode(_ json: String) -> String {
            Data(json.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let iat = Int(Date.now.timeIntervalSince1970 - age)
        let refresh = "\(encode(#"{"alg":"HS256"}"#)).\(encode(#"{"type":"refresh","iat":\#(iat),"exp":\#(iat + 2_592_000)}"#)).\(name)"
        return AuthTokens(accessToken: "access-\(name)", refreshToken: refresh)
    }

    static func credentials(_ connection: Connection, _ tokens: AuthTokens, changedAt: Date = .now) -> WatchCredentials {
        WatchCredentials(entries: [WatchCredentials.Entry(connection: connection, tokens: tokens, tokensChangedAt: changedAt)])
    }

    @Test func adoptsNewerTokensOfThePairedDeviceBeforeRefreshing() async {
        let client = MockClient(connection: Fixtures.connection())
        let hearth = makeHearth([client])
        let id = client.connection.id
        let own = Self.tokens("own", issuedAgo: 3600)
        let phone = Self.tokens("phone", issuedAgo: 10)
        hearth.environment.tokenStore.set(own, for: id)
        hearth.connections.pairedDeviceCredentials = { _ in Self.credentials(client.connection, phone) }

        let adopted = await hearth.environment.tokenStore.externalTokens(for: id, current: own, reason: .aboutToRefresh)
        #expect(adopted == phone)
        #expect(hearth.environment.tokenStore.cachedOrStoredTokens(for: id) == phone)
        #expect(hearth.environment.credentials.tokens(for: id) == phone)
    }

    @Test func neverReplacesTheValidRefreshTokenWithAnOlderOne() async {
        let client = MockClient(connection: Fixtures.connection())
        let hearth = makeHearth([client])
        let id = client.connection.id
        // This device rotated the session last; the other one still has the previous pair.
        let own = Self.tokens("own", issuedAgo: 10)
        let stale = Self.tokens("stale", issuedAgo: 3600)
        hearth.environment.tokenStore.set(own, for: id)
        hearth.connections.pairedDeviceCredentials = { _ in Self.credentials(client.connection, stale) }

        #expect(await hearth.environment.tokenStore.externalTokens(for: id, current: own, reason: .aboutToRefresh) == nil)
        #expect(hearth.environment.tokenStore.cachedOrStoredTokens(for: id) == own)
    }

    @Test func adoptsOtherTokensAfterTheServerRejectedOurs() async {
        let client = MockClient(connection: Fixtures.connection())
        let hearth = makeHearth([client])
        let id = client.connection.id
        let rejected = AuthTokens(accessToken: "access-old", refreshToken: "refresh-old")
        let watch = AuthTokens(accessToken: "access-watch", refreshToken: "refresh-watch")
        hearth.environment.tokenStore.set(rejected, for: id)
        hearth.connections.pairedDeviceCredentials = { _ in Self.credentials(client.connection, watch) }

        #expect(await hearth.environment.tokenStore.externalTokens(for: id, current: rejected, reason: .aboutToRefresh) == nil)
        #expect(await hearth.environment.tokenStore.externalTokens(for: id, current: rejected, reason: .refreshRejected) == watch)
        #expect(hearth.environment.tokenStore.cachedOrStoredTokens(for: id) == watch)
    }

    @Test func usesTokensThatArrivedWhileAsking() async {
        let client = MockClient(connection: Fixtures.connection())
        let hearth = makeHearth([client])
        let id = client.connection.id
        let rejected = Self.tokens("rejected", issuedAgo: 7200)
        let transferred = Self.tokens("transferred", issuedAgo: 600)
        hearth.environment.tokenStore.set(rejected, for: id)
        let store = hearth.environment.tokenStore
        // The watch isn't reachable, but its queued transfer is delivered meanwhile.
        hearth.connections.pairedDeviceCredentials = { _ in
            store.set(transferred, for: id)
            return nil
        }
        #expect(await store.externalTokens(for: id, current: rejected, reason: .refreshRejected) == transferred)
    }

    @Test func pushedCredentialsAreOrderedByTheServersIssueTime() async {
        let client = MockClient(connection: Fixtures.connection())
        let hearth = makeHearth([client])
        let id = client.connection.id
        let own = Self.tokens("own", issuedAgo: 10)
        hearth.environment.tokenStore.set(own, for: id)

        // An older pair announced with a later (device clock) change date must not win.
        let older = Self.tokens("older", issuedAgo: 3600)
        #expect(await hearth.connections.applyWatchCredentials(Self.credentials(client.connection, older, changedAt: .now.addingTimeInterval(3600))).isEmpty)
        #expect(hearth.environment.tokenStore.cachedOrStoredTokens(for: id) == own)

        let newer = Self.tokens("newer", issuedAgo: 1)
        #expect(await hearth.connections.applyWatchCredentials(Self.credentials(client.connection, newer, changedAt: .distantPast)) == [id])
        #expect(hearth.environment.tokenStore.cachedOrStoredTokens(for: id) == newer)
    }

    @Test func refreshedTokensAreReported() async {
        let client = MockClient(connection: Fixtures.connection())
        let hearth = makeHearth([client])
        var reported: [ConnectionID] = []
        hearth.connections.tokensRefreshed = { reported.append($0) }
        await hearth.environment.tokenStore.store(AuthTokens(accessToken: "a", refreshToken: "r"), for: client.connection.id)
        #expect(reported == [client.connection.id])
    }
}
