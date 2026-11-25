import Foundation
import HearthModel
import os

/// A Claude model offered for ad detection (prices in USD per million tokens, for the estimate in the settings).
public struct AnthropicModel: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let inputPrice: Double
    public let outputPrice: Double
    /// Server-side refusal fallback (`fallbacks: "default"`) is available for this model.
    let supportsFallbacks: Bool

    public static let all: [AnthropicModel] = [
        AnthropicModel(id: "claude-opus-5-5", name: "Claude Opus 5.5", inputPrice: 4, outputPrice: 20, supportsFallbacks: true),
        AnthropicModel(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", inputPrice: 2, outputPrice: 10, supportsFallbacks: true),
        AnthropicModel(id: "claude-haiku-5-5", name: "Claude Haiku 5.5", inputPrice: 0.10, outputPrice: 0.50, supportsFallbacks: false),
    ]

    public static func model(id: String) -> AnthropicModel? {
        all.first { $0.id == id }
    }

    /// Rough cost in USD for one hour of speech (~60 000 characters ≈ 20 000 input tokens, ~1 500 output tokens
    /// including thinking).
    public var costPerHour: Double {
        20_000 / 1_000_000 * inputPrice + 1_500 / 1_000_000 * outputPrice
    }
}

public enum AnthropicError: Error, Equatable, Sendable {
    case invalidAPIKey
    case permissionDenied
    /// The request was rejected, e.g. no credit left (message from the API).
    case rejected(String)
    case rateLimited
    case overloaded
    case server(Int)
    /// Claude declined the request (`stop_reason: "refusal"`).
    case refused
    case invalidResponse

    /// Errors that affect every request – stop instead of falling back window by window.
    var isFatal: Bool {
        switch self {
        case .invalidAPIKey, .permissionDenied, .rejected: true
        default: false
        }
    }
}

extension AnthropicError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            String(localized: "The Anthropic API key is invalid.", bundle: .module)
        case .permissionDenied:
            String(localized: "The Anthropic API key isn't allowed to use this model.", bundle: .module)
        case .rejected(let message):
            String(localized: "Anthropic rejected the request: \(message)", bundle: .module)
        case .rateLimited:
            String(localized: "Too many requests to Anthropic. Try again later.", bundle: .module)
        case .overloaded, .server:
            String(localized: "Anthropic is temporarily unavailable.", bundle: .module)
        case .refused:
            String(localized: "Claude declined to analyze this transcript.", bundle: .module)
        case .invalidResponse:
            String(localized: "Anthropic sent an unexpected response.", bundle: .module)
        }
    }
}

/// Claude via the Messages API with the user's own key. The whole transcript fits into one request (1M context).
struct AnthropicAdModelRunner: AdModelRunner {
    let apiKey: String
    let model: AnthropicModel
    var session: URLSession = AnthropicAPI.session

    var method: AdAnalysis.Method { .anthropic }
    var modelName: String? { model.name }
    /// No chunking in practice: ~430 000 tokens (about 25 hours of speech) fit one request of the 1M-token context.
    /// Only longer items are split, so no request can exceed the context.
    var windowCharacters: Int { 1_500_000 }

    private static let logger = Logger(subsystem: "me.robinferch.hearth", category: "Anthropic")

    func findAds(instructions: String, transcript: String) async throws -> [AdBlockCandidate] {
        let request = try AnthropicAPI.messagesRequest(apiKey: apiKey, model: model, instructions: instructions, transcript: transcript)
        var attempt = 0
        while true {
            attempt += 1
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AnthropicError.invalidResponse }
            if http.statusCode == 200 {
                return try AnthropicAPI.parseAds(from: data)
            }
            let error = AnthropicAPI.error(status: http.statusCode, data: data)
            Self.logger.error("Anthropic request failed with \(http.statusCode): \(String(describing: error), privacy: .public)")
            guard attempt < 3, [.rateLimited, .overloaded].contains(error) || error == .server(http.statusCode) else {
                throw error
            }
            let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init) ?? Double(attempt * 5)
            try await Task.sleep(for: .seconds(min(retryAfter, 30)))
        }
    }
}

/// Request building and response parsing for the Anthropic Messages API (no official Swift SDK: plain HTTPS).
enum AnthropicAPI {
    static let baseURL = URL(string: "https://api.anthropic.com/v1/")!
    static let version = "2026-10-21"
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // The whole transcript goes in one non-streamed request; a long audiobook can take minutes to analyze.
        configuration.timeoutIntervalForRequest = 900
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    /// JSON schema of the answer (structured outputs).
    static var schema: [String: Any] { [
        "type": "object",
        "properties": [
            "ads": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "firstLine": ["type": "integer", "description": "Number of the first line of the advertising block"],
                        "lastLine": ["type": "integer", "description": "Number of the last line of the advertising block"],
                        "advertiser": [
                            "anyOf": [["type": "string"], ["type": "null"]],
                            "description": "The advertised brand, product or service, or null if not named",
                        ],
                    ],
                    "required": ["firstLine", "lastLine", "advertiser"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["ads"],
        "additionalProperties": false,
    ] }

    static func messagesRequest(apiKey: String, model: AnthropicModel, instructions: String, transcript: String) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "messages"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(version, forHTTPHeaderField: "anthropic-version")
        var body: [String: Any] = [
            "model": model.id,
            "max_tokens": 16_000,
            "system": instructions,
            "messages": [["role": "user", "content": transcript]],
            "output_config": ["format": ["type": "json_schema", "schema": schema]],
        ]
        if model.supportsFallbacks {
            // On a policy decline (true crime can trigger one), the API re-runs the request on a fallback model.
            request.setValue(fallbackBeta, forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// A free request that only checks the key (lists one model).
    static func validationRequest(apiKey: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "models").appending(queryItems: [URLQueryItem(name: "limit", value: "1")]))
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(version, forHTTPHeaderField: "anthropic-version")
        return request
    }

    private struct MessageResponse: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }

        let content: [Block]
        let stopReason: String?

        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
        }
    }

    private struct Answer: Decodable {
        let ads: [AdBlockCandidate]
    }

    static func parseAds(from data: Data) throws -> [AdBlockCandidate] {
        let response: MessageResponse
        do {
            response = try JSONDecoder().decode(MessageResponse.self, from: data)
        } catch {
            throw AnthropicError.invalidResponse
        }
        // Check the stop reason before reading the content.
        switch response.stopReason {
        case "refusal":
            throw AnthropicError.refused
        case "max_tokens":
            throw AnthropicError.invalidResponse
        default:
            break
        }
        let text = response.content.filter { $0.type == "text" }.compactMap(\.text).joined()
        guard let json = text.data(using: .utf8), let answer = try? JSONDecoder().decode(Answer.self, from: json) else {
            throw AnthropicError.invalidResponse
        }
        return answer.ads
    }

    private struct ErrorResponse: Decodable {
        struct Detail: Decodable {
            let type: String?
            let message: String?
        }

        let error: Detail?
    }

    static func error(status: Int, data: Data) -> AnthropicError {
        let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error?.message
        switch status {
        case 401: return .invalidAPIKey
        case 403: return .permissionDenied
        case 400, 404, 413: return .rejected(message ?? "HTTP \(status)")
        case 429: return .rateLimited
        case 529: return .overloaded
        default: return .server(status)
        }
    }
}

/// Checks an Anthropic API key with a free request.
public enum AnthropicKeyValidator {
    public static func validate(_ apiKey: String) async throws {
        let (data, response) = try await AnthropicAPI.session.data(for: AnthropicAPI.validationRequest(apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)))
        guard let http = response as? HTTPURLResponse else { throw AnthropicError.invalidResponse }
        guard http.statusCode == 200 else {
            throw AnthropicAPI.error(status: http.statusCode, data: data)
        }
    }
}
