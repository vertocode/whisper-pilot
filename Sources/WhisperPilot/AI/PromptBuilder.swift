import Foundation

/// Lightweight Sendable view of a chat exchange to hand off across actor boundaries when
/// building a prompt. Keeps `PromptBuilder` free of dependencies on UI types.
struct ChatTurn: Sendable {
    enum Role: String, Sendable { case user, assistant }
    let role: Role
    let text: String
}

enum PromptBuilder {
    /// Triggered by the question detector when someone in the meeting asks something.
    static func build(context: ConversationSnapshot, history: [ChatTurn], question: String, style: ResponseStyle) -> Prompt {
        let system = """
        You are an ambient real-time copilot for a live conversation. The user cannot type to you. \
        They will hear or read what you produce while they are still talking. Be direct. Lead with the answer. \
        Never say "as an AI" or "I'd be happy to help". Match the requested style.

        Style: \(style.rawValue) — \(style.description)
        """
        return Prompt(
            systemInstruction: system,
            context: contextBlock(transcript: context, history: history),
            question: question,
            style: style
        )
    }

    /// Triggered by the periodic auto-send timer. Asks for a brief recap + a useful next question.
    static func buildAutoSend(context: ConversationSnapshot, history: [ChatTurn], style: ResponseStyle) -> Prompt {
        let system = """
        You are an ambient real-time copilot. The user has set you to summarize periodically. \
        Give 2-3 short bullet observations about what's happened recently and one concrete \
        follow-up question or talking point the user could raise. Be terse. \
        If the prior chat below shows you've already covered something, don't repeat it.

        Style: \(style.rawValue) — \(style.description)
        """
        return Prompt(
            systemInstruction: system,
            context: contextBlock(transcript: context, history: history),
            question: "Periodic check-in. Summarize the last minute and propose one useful follow-up.",
            style: style
        )
    }

    /// Triggered when the user types a prompt in the composer. The transcript AND the prior
    /// chat are both included so multi-turn references ("translate that", "explain more",
    /// "what did they say about X") resolve naturally.
    static func buildUserQuery(context: ConversationSnapshot, history: [ChatTurn], query: String, style: ResponseStyle) -> Prompt {
        let system = """
        You are an ambient real-time copilot. The user has typed a question or instruction \
        for you. Use the provided live transcript and the prior chat as context. If the user \
        references "they", "that", or "what was said", interpret it against the transcript or \
        the most recent assistant turn. Be direct.

        Style: \(style.rawValue) — \(style.description)
        """
        return Prompt(
            systemInstruction: system,
            context: contextBlock(transcript: context, history: history),
            question: query,
            style: style
        )
    }

    private static func contextBlock(transcript: ConversationSnapshot, history: [ChatTurn]) -> String {
        let recent = transcript.recentLines.suffix(20).joined(separator: "\n")
        let topics = transcript.topics.isEmpty ? "" : "\nTopics so far: \(transcript.topics.joined(separator: ", "))"

        let chatBlock: String
        if history.isEmpty {
            chatBlock = ""
        } else {
            let formatted = history.suffix(10).map { turn in
                let label = turn.role == .user ? "User" : "You (assistant)"
                return "\(label): \(turn.text)"
            }.joined(separator: "\n")
            chatBlock = "\n\nPrior chat between you and the user (most recent at the bottom):\n\(formatted)"
        }

        return """
        Recent meeting transcript (most recent at the bottom):
        \(recent)\(topics)\(chatBlock)
        """
    }
}
