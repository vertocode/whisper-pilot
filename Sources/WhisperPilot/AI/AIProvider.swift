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

protocol AIProvider: AnyObject, Sendable {
    func streamCompletion(prompt: Prompt) -> AsyncThrowingStream<String, Error>
    func classifyQuestion(_ text: String) async throws -> QuestionClass
    func extractTopics(from text: String) async throws -> [String]
    func summarize(_ text: String) async throws -> String
}
