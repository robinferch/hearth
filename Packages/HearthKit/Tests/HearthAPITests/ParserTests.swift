import Foundation
import HearthModel
import Testing
@testable import HearthAPI

@Suite struct PKCETests {
    @Test func challengeMatchesRFC7636Example() {
        // RFC 7636, Appendix B.
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func verifierIsLongAlphanumericAndRandom() {
        let verifier = PKCE.makeVerifier()
        #expect(verifier.count >= 64)
        #expect(verifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
        #expect(verifier != PKCE.makeVerifier())
    }

    @Test func challengeIsBase64URLWithoutPadding() {
        let challenge = PKCE.challenge(for: PKCE.makeVerifier(length: 128))
        #expect(challenge.count == 43)
        #expect(!challenge.contains("=") && !challenge.contains("+") && !challenge.contains("/"))
    }
}

@Suite struct ChapterParserTests {
    @Test func parsesHTMLShowNotes() {
        let description = "<p>Intro text</p><p>00:00 Intro<br>12:30 The Assassination<br/>1:05:10 Mobilization &amp; War</p>"
        let chapters = ChapterParser.parse(description: description, duration: 5000)
        #expect(chapters == [
            Chapter(id: 0, start: 0, end: 750, title: "Intro"),
            Chapter(id: 1, start: 750, end: 3910, title: "The Assassination"),
            Chapter(id: 2, start: 3910, end: 5000, title: "Mobilization & War"),
        ])
    }

    @Test func supportsBracketsAndSeparators() {
        let description = """
        (00:00) - Welcome
        [05:15] – News
        10:00: Interview
        01:02:03 | Outro
        """
        let chapters = ChapterParser.parse(description: description, duration: 4000)
        #expect(chapters.map(\.title) == ["Welcome", "News", "Interview", "Outro"])
        #expect(chapters.map(\.start) == [0, 315, 600, 3723])
    }

    @Test func ignoresInvalidTimestampsAndProse() {
        let description = """
        We met at 12:30pm for lunch.
        Call 555:1234 now
        00:00 Start
        99:99 Broken
        3:61 Broken too
        20:00 Middle
        """
        let chapters = ChapterParser.parse(description: description, duration: 3000)
        #expect(chapters.map(\.title) == ["Start", "Middle"])
    }

    @Test func requiresAtLeastTwoChapters() {
        #expect(ChapterParser.parse(description: "00:00 Only one", duration: 100).isEmpty)
        #expect(ChapterParser.parse(description: "No timestamps here", duration: 100).isEmpty)
    }

    @Test func dropsChaptersBeyondDurationAndSorts() {
        let chapters = ChapterParser.parse(description: "10:00 B\n00:00 A\n59:00 Too late", duration: 1200)
        #expect(chapters.map(\.title) == ["A", "B"])
        #expect(chapters.last?.end == 1200)
    }

    @Test func decodesEntities() {
        #expect(ChapterParser.decodeEntities("Tom &amp; Jerry &#39;s &#x41; &nbsp;x &unknown;") == "Tom & Jerry 's A  x &unknown;")
    }
}

@Suite struct SocketIOPacketTests {
    @Test func parsesOpenHandshake() throws {
        let packet = EnginePacket.parse(#"0{"sid":"abc","upgrades":[],"pingInterval":25000,"pingTimeout":20000,"maxPayload":1000000}"#)
        #expect(packet == .open(.init(sid: "abc", pingInterval: .milliseconds(25000), pingTimeout: .milliseconds(20000))))
    }

    @Test func parsesPingAndEncodesPong() {
        #expect(EnginePacket.parse("2") == .ping(""))
        #expect(EnginePacket.pong("").encoded == "3")
        #expect(EnginePacket.parse("3probe") == .pong("probe"))
    }

    @Test func parsesNamespaceConnect() {
        #expect(EnginePacket.parse(#"40{"sid":"xyz"}"#) == .message(.connect(sid: "xyz")))
        #expect(EnginePacket.parse("40") == .message(.connect(sid: nil)))
        #expect(EnginePacket.parse("40/,") == .message(.connect(sid: nil)))
        #expect(EnginePacket.parse("40/admin,") == nil)
    }

    @Test func parsesEventWithPayload() throws {
        let frame = #"42["user_item_progress_updated",{"id":"mp_1","data":{"id":"mp_1","libraryItemId":"li_1","progress":0.5}}]"#
        guard case .message(.event(let name, let arguments, let ackID)) = EnginePacket.parse(frame) else {
            Issue.record("Expected event")
            return
        }
        #expect(name == "user_item_progress_updated")
        #expect(ackID == nil)
        let argument = try #require(arguments.first)
        let object = try #require(try JSONSerialization.jsonObject(with: argument) as? [String: Any])
        #expect(object["id"] as? String == "mp_1")
    }

    @Test func parsesEventWithAckIDAndNoArguments() {
        #expect(EnginePacket.parse(#"4212["init"]"#) == .message(.event(name: "init", arguments: [], ackID: 12)))
    }

    @Test func encodesAuthEvent() {
        let packet = EnginePacket.message(.event("auth", strings: [#"tok"en/1"#]))
        #expect(packet.encoded == #"42["auth","tok\"en/1"]"#)
        #expect(EnginePacket.message(.connect(sid: nil)).encoded == "40")
    }

    @Test func parsesConnectErrorAndDisconnect() {
        #expect(EnginePacket.parse(#"44{"message":"Not authorized"}"#) == .message(.connectError(message: "Not authorized")))
        #expect(EnginePacket.parse("41") == .message(.disconnect))
        #expect(EnginePacket.parse("1") == .close)
        #expect(EnginePacket.parse("") == nil)
        #expect(EnginePacket.parse("42not json") == nil)
    }

    @Test func backoffGrowsAndIsCapped() {
        #expect(SocketIOClient.backoff(attempt: 1, maximum: .seconds(60)) >= .seconds(1))
        #expect(SocketIOClient.backoff(attempt: 1, maximum: .seconds(60)) <= .milliseconds(1200))
        #expect(SocketIOClient.backoff(attempt: 4, maximum: .seconds(60)) >= .seconds(8))
        #expect(SocketIOClient.backoff(attempt: 30, maximum: .seconds(60)) <= .seconds(72))
    }
}

@Suite struct LenientDecodingTests {
    struct Probe: Decodable {
        var string: String?
        var number: Double?
        var flag: Bool?
        var strings: [String]
        var series: [SeriesReferencePayload]

        init(from decoder: any Decoder) throws {
            let c = try decoder.lenient()
            string = c.string("string")
            number = c.double("number")
            flag = c.bool("flag")
            strings = c.strings("strings")
            series = c.array("series")
        }
    }

    @Test func acceptsPolymorphicValues() throws {
        let json = #"{"string": 12, "number": "3.5", "flag": 1, "strings": ["a", 2, null, ""], "series": {"id": "s", "name": "Name", "sequence": 4}}"#
        let probe = try JSONDecoder().decode(Probe.self, from: Data(json.utf8))
        #expect(probe.string == "12")
        #expect(probe.number == 3.5)
        #expect(probe.flag == true)
        #expect(probe.strings == ["a", "2"])
        #expect(probe.series.map(\.sequence) == ["4"])
    }

    @Test func skipsBrokenArrayElements() throws {
        let json = #"{"series": [{"name": "A"}, {"id": "no-name"}, 5, {"name": "B", "sequence": "1.5"}]}"#
        let probe = try JSONDecoder().decode(Probe.self, from: Data(json.utf8))
        #expect(probe.series.map(\.name) == ["A", "B"])
        #expect(probe.strings.isEmpty && probe.string == nil && probe.flag == nil)
    }
}
