import Foundation

/// Engine.IO v4 packet (one WebSocket text frame).
enum EnginePacket: Equatable, Sendable {
    struct Handshake: Equatable, Sendable {
        var sid: String?
        var pingInterval: Duration
        var pingTimeout: Duration
    }

    case open(Handshake)
    case close
    case ping(String)
    case pong(String)
    case message(SocketPacket)
    case upgrade
    case noop

    /// Parses an Engine.IO text frame. Returns `nil` for malformed frames.
    static func parse(_ text: String) -> EnginePacket? {
        guard let type = text.first else { return nil }
        let payload = String(text.dropFirst())

        switch type {
        case "0":
            let object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] ?? [:]
            let interval = (object["pingInterval"] as? NSNumber)?.intValue ?? 25000
            let timeout = (object["pingTimeout"] as? NSNumber)?.intValue ?? 20000
            return .open(Handshake(sid: object["sid"] as? String, pingInterval: .milliseconds(interval), pingTimeout: .milliseconds(timeout)))
        case "1":
            return .close
        case "2":
            return .ping(payload)
        case "3":
            return .pong(payload)
        case "4":
            return SocketPacket.parse(payload).map(EnginePacket.message)
        case "5":
            return .upgrade
        case "6":
            return .noop
        default:
            return nil
        }
    }

    var encoded: String {
        switch self {
        case .open: "0"
        case .close: "1"
        case .ping(let data): "2" + data
        case .pong(let data): "3" + data
        case .message(let packet): "4" + packet.encoded
        case .upgrade: "5"
        case .noop: "6"
        }
    }
}

/// Socket.IO v4 packet carried inside an Engine.IO message. Only the default namespace is used.
enum SocketPacket: Equatable, Sendable {
    case connect(sid: String?)
    case disconnect
    /// `name` plus the JSON encoded arguments (`[arg0, arg1, …]` without the name).
    case event(name: String, arguments: [Data], ackID: Int?)
    case ack(id: Int, arguments: [Data])
    case connectError(message: String?)

    static func parse(_ text: String) -> SocketPacket? {
        guard let type = text.first else { return nil }
        var rest = Substring(text.dropFirst())

        // Optional namespace ("/admin,"). Only the root namespace is relevant.
        if rest.hasPrefix("/") {
            let comma = rest.firstIndex(of: ",")
            let namespace = comma.map { rest[..<$0] } ?? rest
            guard namespace == "/" else { return nil }
            rest = comma.map { rest[rest.index(after: $0)...] } ?? ""
        }
        return parse(type: type, rest: rest)
    }

    private static func parse(type: Character, rest: Substring) -> SocketPacket? {
        var rest = rest
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        let ackID = digits.isEmpty ? nil : Int(digits)
        rest = rest.dropFirst(digits.count)

        switch type {
        case "0":
            let object = (try? JSONSerialization.jsonObject(with: Data(rest.utf8))) as? [String: Any]
            return .connect(sid: object?["sid"] as? String)
        case "1":
            return .disconnect
        case "2", "5":
            guard let array = jsonArray(rest), let name = array.first as? String else { return nil }
            return .event(name: name, arguments: array.dropFirst().compactMap(jsonData), ackID: ackID)
        case "3", "6":
            guard let ackID, let array = jsonArray(rest) else { return nil }
            return .ack(id: ackID, arguments: array.compactMap(jsonData))
        case "4":
            let object = try? JSONSerialization.jsonObject(with: Data(rest.utf8), options: [.fragmentsAllowed])
            let message = (object as? [String: Any])?["message"] as? String ?? object as? String
            return .connectError(message: message)
        default:
            return nil
        }
    }

    private static func jsonArray(_ text: Substring) -> [Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) as? [Any]
    }

    private static func jsonData(_ value: Any) -> Data? {
        if value is NSNull {
            return Data("null".utf8)
        }
        return try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    }

    var encoded: String {
        switch self {
        case .connect:
            return "0"
        case .disconnect:
            return "1"
        case .connectError(let message):
            return "4" + (message.flatMap { Self.encodeJSON(["message": $0]) } ?? "")
        case .event(let name, let arguments, let ackID):
            let nameJSON = Self.encodeJSON(name) ?? "\"\""
            let parts = [nameJSON] + arguments.map { String(decoding: $0, as: UTF8.self) }
            return "2" + (ackID.map(String.init) ?? "") + "[" + parts.joined(separator: ",") + "]"
        case .ack(let id, let arguments):
            return "3\(id)[" + arguments.map { String(decoding: $0, as: UTF8.self) }.joined(separator: ",") + "]"
        }
    }

    /// Convenience for emitting an event with string arguments (`42["auth","token"]`).
    static func event(_ name: String, strings: [String]) -> SocketPacket {
        .event(name: name, arguments: strings.compactMap { encodeJSONData($0) }, ackID: nil)
    }

    private static func encodeJSON(_ value: Any) -> String? {
        encodeJSONData(value).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func encodeJSONData(_ value: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    }
}
