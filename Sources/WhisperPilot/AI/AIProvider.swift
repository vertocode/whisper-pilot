import Foundation

enum ResponseStyle: String, CaseIterable, Codable, Sendable {
    case concise
    case detailed
    case strategic
    case followUp = "follow-up"

    var displayName: String {
        switch self {
        case .concise: return "Concise"
        case .detailed: return "Detailed"
        case .strategic: return "Strategic"
        case .followUp: return "Follow-up"
        }
    }

    var description: String {
        switch self {
        case .concise: return "Short, conversational answer the user can deliver out loud."
        case .detailed: return "Thorough explanation with reasoning and concrete details."
        case .strategic: return "Trade-offs, risks, and considerations relevant to the question."
        case .followUp: return "A handful of smart follow-up questions the user could ask next."
        }
    }
}

struct Prompt: Sendable {
    let systemInstruction: String
    let context: String
    let question: String
    let style: ResponseStyle
    /// Optional base64-encoded JPEG attached as multimodal input (e.g. "see my screen"
    /// composer toggle). Providers without vision support should ignore this gracefully.
    var imageJPEGBase64: String? = nil
}

enum QuestionClass: String, Codable, Sendable {
    case technical
    case conversational
    case status
    case interview
    case salesObjection = "sales_objection"
    case followUp = "follow_up"
    case other
}

/// Why an AI stream ended. Mirrors Gemini's `finishReason` enum, but the abstraction
/// is provider-agnostic so a future Ollama / Anthropic provider can populate the
/// same value. `.stop` is the only "clean" outcome — every other case means the
/// model did not produce a complete answer.
enum AIFinishReason: Sendable, Equatable {
    /// Model decided it was done. Normal, complete response.
    case stop
    /// Hit the configured output-token cap. Response is partial; user-visible
    /// content may end mid-sentence.
    case maxTokens
    /// Safety filter blocked further generation. Content already streamed is what
    /// the model produced before the block.
    case safety
    /// Recitation / copyright filter aborted generation.
    case recitation
    /// Provider sent a value we don't recognise, or none at all. Used both for
    /// genuinely-unknown reasons and for "the stream ended without a finishReason
    /// in any chunk" — in the latter case the connection likely dropped.
    case other(String?)

    var isClean: Bool {
        if case .stop = self { return true }
        return false
    }

    /// Short human-readable explanation suitable for a system-note suffix. Returns
    /// `nil` for `.stop` because there's nothing to surface.
    var diagnosticMessage: String? {
        switch self {
        case .stop:
            return nil
        case .maxTokens:
            return "response was cut off at the model's output-token limit"
        case .safety:
            return "response was blocked by Gemini's safety filter"
        case .recitation:
            return "response was stopped by Gemini's recitation / copyright filter"
        case .other(let raw):
            if let raw, !raw.isEmpty {
                return "stream ended unexpectedly (\(raw))"
            }
            return "stream ended without a finish reason — likely a network drop or server-side cut"
        }
    }
}

/// One unit of output from `AIProvider.streamCompletion`. Most events are text
/// deltas to append to the in-progress assistant bubble; the terminal event is a
/// `.finish` carrying the provider's reason for stopping, which the coordinator
/// uses to decide whether to flag the response as truncated.
enum AIStreamEvent: Sendable {
    case delta(String)
    case finish(AIFinishReason)
}

protocol AIProvider: AnyObject, Sendable {
    func streamCompletion(prompt: Prompt) -> AsyncThrowingStream<AIStreamEvent, Error>
    func classifyQuestion(_ text: String) async throws -> QuestionClass
    func extractTopics(from text: String) async throws -> [String]
    func summarize(_ text: String) async throws -> String
}
