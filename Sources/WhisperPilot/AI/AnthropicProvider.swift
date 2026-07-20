import Foundation
import OSLog

/// Streaming Anthropic provider using the Messages API with `stream: true`. The
/// wire protocol is SSE with named event types (`content_block_delta`,
/// `message_delta`, `message_stop`, …); we filter to `content_block_delta`
/// events carrying text deltas, plus the terminal `message_delta` for the
/// finish reason.
///
/// Mirrors `GeminiProvider`'s shape: same `AIProvider` conformance, same
/// `Prompt → AsyncThrowingStream<AIStreamEvent, Error>` contract, same
/// `AIFinishReason` mapping, same `singleShot`-based helpers for the
/// non-streaming utility calls (`classifyQuestion`, `extractTopics`,
/// `summarize`). Anything that already consumes `AIProvider` (the coordinator,
/// the trigger pipeline) works against Claude with zero changes once the right
/// instance lands in `aiProvider`.
final class AnthropicProvider: AIProvider, @unchecked Sendable {
    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let log = Logger(subsystem: "com.whisperpilot.app", category: "Anthropic")

    /// `anthropic-version` header value. Pinned to a known-good date so a new
    /// breaking API revision can't silently change shape under us.
    private static let apiVersion = "2023-06-01"

    init(apiKey: String, model: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    func streamCompletion(prompt: Prompt) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    self.log.info("Anthropic stream request → model=\(self.model, privacy: .public), question=\"\(prompt.question, privacy: .private)\", style=\(prompt.style.rawValue, privacy: .public)")
                    let reason = try await stream(prompt: prompt, continuation: continuation)
                    self.log.info("Anthropic stream complete (reason=\(String(describing: reason), privacy: .public))")
                    continuation.yield(.finish(reason))
                    continuation.finish()
                } catch {
                    self.log.error("Anthropic stream failed: \(String(describing: error), privacy: .public)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func classifyQuestion(_ text: String) async throws -> QuestionClass {
        let instruction = """
        Classify the following question into exactly one of these categories: \
        technical, conversational, status, interview, sales_objection, follow_up, other. \
        Respond with only the category string.

        Question: \(text)
        """
        let raw = try await singleShot(prompt: instruction, maxTokens: 32)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return QuestionClass(rawValue: trimmed) ?? .other
    }

    func extractTopics(from text: String) async throws -> [String] {
        let instruction = """
        Extract up to 6 short topic keywords from the following text. \
        Return a comma-separated list, no explanations.

        Text: \(text)
        """
        let raw = try await singleShot(prompt: instruction, maxTokens: 128)
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func summarize(_ text: String) async throws -> String {
        try await singleShot(prompt: "Summarize the following in 2-3 sentences:\n\n\(text)", maxTokens: 400)
    }

    // MARK: - HTTP

    private func stream(
        prompt: Prompt,
        continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) async throws -> AIFinishReason {
        let body = try encode(requestBody(for: prompt, stream: true))
        let request = makeRequest(body: body)

        let (bytes, response) = try await session.bytes(for: request)
        try await ensureSuccess(response: response, bytes: bytes)

        // Anthropic SSE uses named events. The line stream interleaves
        // `event: <name>` and `data: <json>` lines (plus blank separators).
        // We track the most recent event name and dispatch the next `data:`
        // line against it. `content_block_delta` carries text; `message_delta`
        // carries the terminal `stop_reason` we need for `AIFinishReason`.
        var currentEvent: String?
        var stopReason: String?

        for try await line in bytes.lines {
            try Task.checkCancellation()
            if line.hasPrefix("event:") {
                currentEvent = line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            guard let data = payload.data(using: .utf8) else { continue }

            switch currentEvent {
            case "content_block_delta":
                if let chunk = try? JSONDecoder().decode(AnthropicContentBlockDelta.self, from: data),
                   let text = chunk.delta?.text, !text.isEmpty {
                    continuation.yield(.delta(text))
                }
            case "message_delta":
                if let chunk = try? JSONDecoder().decode(AnthropicMessageDelta.self, from: data),
                   let reason = chunk.delta?.stop_reason {
                    stopReason = reason
                }
            case "error":
                // Mid-stream API errors (overloaded_error, api_error, …) arrive
                // as their own SSE event. Dropping them here would end the
                // stream with no stop_reason and get misreported downstream as
                // a network drop — throw the real cause instead.
                let decoded = try? JSONDecoder().decode(AnthropicStreamErrorEvent.self, from: data)
                throw AnthropicError.stream(
                    type: decoded?.error?.type,
                    message: decoded?.error?.message
                )
            default:
                continue
            }
        }

        return Self.parseFinishReason(stopReason)
    }

    /// Maps Anthropic's `stop_reason` string to our provider-agnostic enum.
    /// Their canonical values:
    ///   - "end_turn"     → model produced a complete response
    ///   - "max_tokens"   → hit the configured token cap
    ///   - "stop_sequence"→ matched a caller-supplied stop sequence (we don't
    ///                       send any, but include for completeness)
    ///   - "tool_use"     → wanted to call a tool (we don't expose tools)
    ///   - "pause_turn"   → server-side pause; never observed in normal use
    ///   - "refusal"      → safety/policy refusal
    private static func parseFinishReason(_ raw: String?) -> AIFinishReason {
        switch raw {
        case "end_turn", "stop_sequence": return .stop
        case "max_tokens":                return .maxTokens
        case "refusal":                   return .safety
        case .some(let other):            return .other(other)
        case .none:                       return .other(nil)
        }
    }

    private func singleShot(prompt: String, maxTokens: Int) async throws -> String {
        let body = try encode(AnthropicRequest.singleUserTurn(model: model, prompt: prompt, maxTokens: maxTokens))
        let request = makeRequest(body: body)
        let (data, response) = try await session.data(for: request)
        try ensureSuccess(response: response, data: data)
        let decoded = try JSONDecoder().decode(AnthropicMessage.self, from: data)
        return decoded.firstText ?? ""
    }

    private func makeRequest(body: Data) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = body
        request.timeoutInterval = 60
        return request
    }

    private func requestBody(for prompt: Prompt, stream: Bool) -> AnthropicRequest {
        let userText = """
        \(prompt.context)

        Question for you: \(prompt.question)

        Respond now in the requested style.
        """
        var content: [AnthropicRequest.ContentBlock] = [.text(userText)]
        if let imageData = prompt.imageJPEGBase64, !imageData.isEmpty {
            content.append(.image(mediaType: "image/jpeg", data: imageData))
        }
        return AnthropicRequest(
            model: model,
            // Match Gemini's 2000-token output budget so style + answer length
            // feel consistent across providers. Detailed / Strategic styles
            // can easily produce 800+ tokens; 2000 is well within Anthropic's
            // per-request limit and matches what the coordinator users see
            // from the Gemini path.
            max_tokens: 2000,
            system: prompt.systemInstruction,
            messages: [.init(role: "user", content: content)],
            temperature: 0.7,
            stream: stream
        )
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func ensureSuccess(response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse else { return }
        if !(200..<300).contains(http.statusCode) {
            let buffer = (try? await bytes.reduce(into: Data(), { $0.append($1) })) ?? Data()
            let body = buffer.isEmpty ? nil : String(data: buffer, encoding: .utf8)
            throw AnthropicError.http(status: http.statusCode, body: body)
        }
    }

    private func ensureSuccess(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8)
            throw AnthropicError.http(status: http.statusCode, body: body)
        }
    }
}

// MARK: - Wire types

private struct AnthropicRequest: Encodable {
    enum ContentBlock: Encodable {
        case text(String)
        case image(mediaType: String, data: String)

        private enum CodingKeys: String, CodingKey {
            case type, text, source
        }
        private struct ImageSource: Encodable {
            let type: String  // "base64"
            let media_type: String
            let data: String
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let s):
                try c.encode("text", forKey: .type)
                try c.encode(s, forKey: .text)
            case .image(let mt, let data):
                try c.encode("image", forKey: .type)
                try c.encode(ImageSource(type: "base64", media_type: mt, data: data), forKey: .source)
            }
        }
    }

    struct Message: Encodable {
        let role: String
        let content: [ContentBlock]
    }

    let model: String
    let max_tokens: Int
    let system: String?
    let messages: [Message]
    let temperature: Double
    let stream: Bool

    static func singleUserTurn(model: String, prompt: String, maxTokens: Int) -> AnthropicRequest {
        AnthropicRequest(
            model: model,
            max_tokens: maxTokens,
            system: nil,
            messages: [.init(role: "user", content: [.text(prompt)])],
            temperature: 0.2,
            stream: false
        )
    }
}

private struct AnthropicMessage: Decodable {
    struct Content: Decodable {
        let type: String
        let text: String?
    }
    let content: [Content]?

    var firstText: String? {
        content?.compactMap { $0.text }.joined()
    }
}

private struct AnthropicContentBlockDelta: Decodable {
    struct Delta: Decodable {
        let type: String?
        let text: String?
    }
    let delta: Delta?
}

private struct AnthropicMessageDelta: Decodable {
    struct Delta: Decodable {
        let stop_reason: String?
    }
    let delta: Delta?
}

private struct AnthropicStreamErrorEvent: Decodable {
    struct Err: Decodable {
        let type: String?
        let message: String?
    }
    let error: Err?
}

enum AnthropicError: LocalizedError {
    case http(status: Int, body: String?)
    case stream(type: String?, message: String?)

    var errorDescription: String? {
        switch self {
        case .stream(let type, let message):
            switch type {
            case "overloaded_error":
                return "Anthropic is temporarily overloaded — retry in a moment."
            default:
                let label = type ?? "unknown"
                let detail = message.map { ": \($0)" } ?? ""
                return "Anthropic stream error (\(label))\(detail)"
            }
        case .http(let status, let body):
            switch status {
            case 401, 403:
                return "Anthropic authentication failed (HTTP \(status)). Check your Claude API key in Settings — it may be invalid or revoked."
            case 429:
                let detail = body.flatMap { extractMessage(from: $0) } ?? ""
                let suffix = detail.isEmpty ? "" : " — \(detail)"
                return "Anthropic rate limit hit (HTTP 429). Wait a moment, switch to a cheaper Claude model in Settings, or check your usage limits at console.anthropic.com.\(suffix)"
            case 400:
                return "Anthropic rejected the request (HTTP 400)\(body.map { ": \($0)" } ?? "")"
            case 404:
                let detail = body.flatMap { extractMessage(from: $0) } ?? ""
                let suffix = detail.isEmpty ? "" : " — \(detail)"
                return "Claude model not found (HTTP 404). The selected model isn't available on this API key — pick a different model in Settings.\(suffix)"
            case 500..<600:
                return "Anthropic server error (HTTP \(status)). Usually transient — retry in a moment."
            default:
                if let body, !body.isEmpty { return "Anthropic error \(status): \(body)" }
                return "Anthropic error \(status)"
            }
        }
    }

    private func extractMessage(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else { return nil }
        return message
    }
}
