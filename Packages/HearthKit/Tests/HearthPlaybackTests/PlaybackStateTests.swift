import Foundation
import Testing
@testable import HearthPlayback

@Suite struct InterruptionLogicTests {
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test func playingOrIntendingCounts() {
        #expect(InterruptionLogic.wasPlaying(isPlaying: true, intendsToPlay: false, systemPausedAt: nil, now: now))
        #expect(InterruptionLogic.wasPlaying(isPlaying: false, intendsToPlay: true, systemPausedAt: nil, now: now))
        #expect(!InterruptionLogic.wasPlaying(isPlaying: false, intendsToPlay: false, systemPausedAt: nil, now: now))
    }

    /// The player reported the system pause before the interruption notification arrived.
    @Test func recentSystemPauseCounts() {
        #expect(InterruptionLogic.wasPlaying(isPlaying: false, intendsToPlay: false, systemPausedAt: now.addingTimeInterval(-0.2), now: now))
        #expect(InterruptionLogic.wasPlaying(isPlaying: false, intendsToPlay: false, systemPausedAt: now.addingTimeInterval(-InterruptionLogic.systemPauseWindow), now: now))
    }

    @Test func oldSystemPauseDoesNotCount() {
        #expect(!InterruptionLogic.wasPlaying(isPlaying: false, intendsToPlay: false, systemPausedAt: now.addingTimeInterval(-10), now: now))
        #expect(!InterruptionLogic.wasPlaying(isPlaying: false, intendsToPlay: false, systemPausedAt: now.addingTimeInterval(5), now: now))
    }
}

@Suite struct StreamingAuthTests {
    private func jwt(exp: TimeInterval) -> String {
        func encode(_ json: String) -> String {
            Data(json.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return encode(#"{"alg":"HS256","typ":"JWT"}"#) + "." + encode(#"{"userId":"root","exp":\#(Int(exp))}"#) + ".signature"
    }

    @Test func readsTokenExpiry() {
        let headers = ["authorization": "Bearer " + jwt(exp: 1_800_000_000), "X-Custom": "1"]
        #expect(StreamingAuth.tokenExpiry(in: headers) == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(StreamingAuth.tokenExpiry(in: ["Authorization": "Bearer legacy-token"]) == nil)
        #expect(StreamingAuth.tokenExpiry(in: [:]) == nil)
    }

    @Test func refreshesShortlyBeforeExpiry() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let soon = ["Authorization": "Bearer " + jwt(exp: now.timeIntervalSince1970 + 60)]
        let expired = ["Authorization": "Bearer " + jwt(exp: now.timeIntervalSince1970 - 600)]
        let fresh = ["Authorization": "Bearer " + jwt(exp: now.timeIntervalSince1970 + 3600)]
        #expect(StreamingAuth.needsRefresh(headers: soon, now: now))
        #expect(StreamingAuth.needsRefresh(headers: expired, now: now))
        #expect(!StreamingAuth.needsRefresh(headers: fresh, now: now))
        #expect(!StreamingAuth.needsRefresh(headers: ["Authorization": "Bearer legacy"], now: now))
    }

    @Test func detectsAuthorizationFailures() {
        #expect(StreamingAuth.isAuthorizationFailure(statusCode: 401, texts: []))
        #expect(StreamingAuth.isAuthorizationFailure(statusCode: -12660, texts: [nil, "HTTP 403: Forbidden"]))
        #expect(!StreamingAuth.isAuthorizationFailure(statusCode: -12938, texts: ["HTTP 404: File Not Found"]))
        #expect(!StreamingAuth.isAuthorizationFailure(statusCode: nil, texts: ["Error 14010"]))
    }

    /// What AVFoundation reports for a stream answered with 401 (OSStatus -16840 wrapped in NSURLErrorDomain).
    @Test func detectsURLAuthenticationErrors() {
        let urlError = NSError(domain: NSURLErrorDomain, code: NSURLErrorUserAuthenticationRequired)
        let wrapped = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [NSUnderlyingErrorKey: urlError])
        #expect(StreamingAuth.isAuthorizationFailure(statusCode: nil, error: urlError, texts: []))
        #expect(StreamingAuth.isAuthorizationFailure(statusCode: -16840, error: wrapped, texts: []))
        #expect(!StreamingAuth.isAuthorizationFailure(statusCode: nil, error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut), texts: []))
    }
}

@MainActor
@Suite struct StartPauseTests {
    /// Pausing while an item is starting must stick; play/pause toggles that request.
    @Test func pauseDuringStartIsRemembered() {
        let player = AudioPlayer()
        player.startingRunID = UUID()
        #expect(player.willPlayAfterStart)

        player.togglePlayPause()
        #expect(player.pausedDuringStart)
        #expect(!player.intendsToPlay)
        #expect(!player.willPlayAfterStart)

        player.togglePlayPause()
        #expect(!player.pausedDuringStart)
        #expect(player.intendsToPlay)
        #expect(player.willPlayAfterStart)
    }

    @Test func pauseWithoutStartDoesNotLeak() {
        let player = AudioPlayer()
        player.pause()
        #expect(!player.pausedDuringStart)
        #expect(!player.willPlayAfterStart)
    }

    @Test func userPauseClearsSystemPause() {
        let player = AudioPlayer()
        player.systemPausedAt = .now
        player.resumeAfterInterruption = true
        player.pause()
        #expect(player.systemPausedAt == nil)
        #expect(!player.resumeAfterInterruption)
    }
}
