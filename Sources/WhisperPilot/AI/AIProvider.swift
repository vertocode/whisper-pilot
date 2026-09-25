import Foundation

enum ResponseStyle: String, CaseIterable, Codable, Sendable {
    case auto
    case concise
    case detailed
    case strategic
    case followUp = "follow-up"

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .concise: return "Concise"
        case .detailed: return "Detailed"
        case .strategic: return "Strategic"
        case .followUp: return "Follow-up"
        }
    }

    /// Doubles as the in-prompt directive (substituted into the system message
    /// in `PromptBuilder`) and as the helper text under the Settings picker, so
    /// every entry must read naturally to both an LLM and a user.
    var description: String {
        switch self {
        case .auto:
            return "Short, natural answer you can say out loud. Goes a bit longer only when the question clearly needs it or someone asks for more detail."
        case .concise:
            return "One or two sentences, the way you'd answer out loud."
        case .detailed:
            return "A fuller answer with the reasoning and an example, still in a spoken tone and short enough to say in about a minute."
        case .strategic:
            return "Talks through the main trade-offs and risks, the way you'd reason out loud in a meeting."
        case .followUp:
            return "One or two smart follow-up questions you could ask next, phrased the way you'd say them, not as a list."
        }
    }
}

struct Prompt: Sendable {
    let systemInstruction: String
    let context: String
    /// Leading part of `context` that doesn't change between calls in a session.
    /// Providers that support prompt caching cache it; others can ignore it.
    var stableContext: String = ""
    let question: String
    let style: ResponseStyle
    /// Optional base64-encoded JPEG attached as multimodal input (e.g. "see my screen"
    /// composer toggle). Providers without vision support should ignore this gracefully.
    var imageJPEGBase64: String? = nil
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
            return "response was blocked by the provider's safety filter"
        case .recitation:
            return "response was stopped by the provider's recitation / copyright filter"
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
    func isQuestionToAnswer(_ text: String) async throws -> Bool
    func extractTopics(from text: String) async throws -> [String]
    func summarize(_ text: String) async throws -> String
}
