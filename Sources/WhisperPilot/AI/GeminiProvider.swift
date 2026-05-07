import Foundation
import OSLog

/// Streaming Gemini provider using the `streamGenerateContent` REST endpoint with `alt=sse`.
/// Each SSE chunk is a JSON object containing partial candidate text; we parse incrementally and
/// yield text deltas as they arrive.
final class GeminiProvider: AIProvider, @unchecked Sendable {
    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let log = Logger(subsystem: "com.whisperpilot.app", category: "Gemini")

    init(apiKey: String, model: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    func streamCompletion(prompt: Prompt) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await stream(prompt: prompt, continuation: continuation)
                    continuation.finish()
                } catch {
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
        let raw = try await singleShot(prompt: instruction)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return QuestionClass(rawValue: trimmed) ?? .other
    }

    func extractTopics(from text: String) async throws -> [String] {
        let instruction = """
        Extract up to 6 short topic keywords from the following text. \
        Return a comma-separated list, no explanations.

        Text: \(text)
        """
        let raw = try await singleShot(prompt: instruction)
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func summarize(_ text: String) async throws -> String {
        try await singleShot(prompt: "Summarize the following in 2-3 sentences:\n\n\(text)")
    }

    // MARK: - HTTP

    private func stream(prompt: Prompt, continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let url = endpoint(streaming: true)
        let body = try encode(requestBody(for: prompt))
        let request = makeRequest(url: url, body: body)

        let (bytes, response) = try await session.bytes(for: request)
        try ensureSuccess(response: response, bytes: bytes)

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty || payload == "[DONE]" { continue }
            guard let data = payload.data(using: .utf8) else { continue }
            if let chunk = try? JSONDecoder().decode(GeminiResponse.self, from: data),
               let text = chunk.firstText, !text.isEmpty {
                continuation.yield(text)
            }
        }
    }

    private func singleShot(prompt: String) async throws -> String {
        let url = endpoint(streaming: false)
        let body = try encode(GeminiRequest.singleUserTurn(prompt))
        let request = makeRequest(url: url, body: body)
        let (data, response) = try await session.data(for: request)
        try ensureSuccess(response: response, data: data)
        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
        return decoded.firstText ?? ""
    }

    private func endpoint(streaming: Bool) -> URL {
        let method = streaming ? "streamGenerateContent" : "generateContent"
        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):\(method)")!
        var items = [URLQueryItem(name: "key", value: apiKey)]
        if streaming { items.append(URLQueryItem(name: "alt", value: "sse")) }
        components.queryItems = items
        return components.url!
    }

    private func makeRequest(url: URL, body: Data) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 60
        return request
    }

    private func requestBody(for prompt: Prompt) -> GeminiRequest {
        let userText = """
        \(prompt.context)

        Other party just asked: \(prompt.question)

        Respond now in the requested style.
        """
        return GeminiRequest(
            systemInstruction: .init(parts: [.init(text: prompt.systemInstruction)]),
            contents: [.init(role: "user", parts: [.init(text: userText)])],
            generationConfig: .init(temperature: 0.7, maxOutputTokens: 600)
        )
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func ensureSuccess(response: URLResponse, bytes: URLSession.AsyncBytes) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if !(200..<300).contains(http.statusCode) {
            throw GeminiError.http(status: http.statusCode, body: nil)
        }
    }

    private func ensureSuccess(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8)
            throw GeminiError.http(status: http.statusCode, body: body)
        }
    }
}

// MARK: - Wire types

private struct GeminiRequest: Encodable {
    struct Part: Codable { let text: String }
    struct Content: Codable {
        let role: String?
        let parts: [Part]
    }
    struct SystemInstruction: Codable {
        let parts: [Part]
    }
    struct GenerationConfig: Codable {
        let temperature: Double
        let maxOutputTokens: Int
    }

    let systemInstruction: SystemInstruction?
    let contents: [Content]
    let generationConfig: GenerationConfig?

    static func singleUserTurn(_ text: String) -> GeminiRequest {
        GeminiRequest(
            systemInstruction: nil,
            contents: [.init(role: "user", parts: [.init(text: text)])],
            generationConfig: .init(temperature: 0.2, maxOutputTokens: 400)
        )
    }
}

private struct GeminiResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable { let text: String? }
            let parts: [Part]?
        }
        let content: Content?
    }
    let candidates: [Candidate]?

    var firstText: String? {
        candidates?.first?.content?.parts?.compactMap(\.text).joined()
    }
}

enum GeminiError: LocalizedError {
    case http(status: Int, body: String?)

    var errorDescription: String? {
        switch self {
        case .http(let status, let body):
            if let body, !body.isEmpty { return "Gemini error \(status): \(body)" }
            return "Gemini error \(status)"
        }
    }
}
