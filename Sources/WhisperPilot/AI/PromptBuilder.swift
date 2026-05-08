import Foundation

enum PromptBuilder {
    /// Triggered by the question detector when someone in the meeting asks something.
    static func build(context: ConversationSnapshot, question: String, style: ResponseStyle) -> Prompt {
        let system = """
        You are an ambient real-time copilot for a live conversation. The user cannot type to you. \
        They will hear or read what you produce while they are still talking. Be direct. Lead with the answer. \
        Never say "as an AI" or "I'd be happy to help". Match the requested style.

        Style: \(style.rawValue) — \(style.description)
        """
        return Prompt(
            systemInstruction: system,
            context: contextBlock(from: context),
            question: question,
            style: style
        )
    }

    /// Triggered by the periodic auto-send timer. Asks for a brief recap + a useful next question.
    static func buildAutoSend(context: ConversationSnapshot, style: ResponseStyle) -> Prompt {
        let system = """
        You are an ambient real-time copilot. The user has set you to summarize periodically. \
        Give 2-3 short bullet observations about what's happened recently and one concrete \
        follow-up question or talking point the user could raise. Be terse.

        Style: \(style.rawValue) — \(style.description)
        """
        return Prompt(
            systemInstruction: system,
            context: contextBlock(from: context),
            question: "Periodic check-in. Summarize the last minute and propose one useful follow-up.",
            style: style
        )
    }

    /// Triggered when the user types a prompt in the composer. The transcript is included as
    /// context so questions like "translate that" or "what did they say about X" work.
    static func buildUserQuery(context: ConversationSnapshot, query: String, style: ResponseStyle) -> Prompt {
        let system = """
        You are an ambient real-time copilot. The user has typed a question or instruction \
        for you. Use the provided live transcript as context. If the user references "they" or \
        "what was said", interpret it against the transcript. Be direct.

        Style: \(style.rawValue) — \(style.description)
        """
        return Prompt(
            systemInstruction: system,
            context: contextBlock(from: context),
            question: query,
            style: style
        )
    }

    private static func contextBlock(from context: ConversationSnapshot) -> String {
        let recent = context.recentLines.suffix(20).joined(separator: "\n")
        let topics = context.topics.isEmpty ? "" : "\nTopics so far: \(context.topics.joined(separator: ", "))"
        return """
        Recent conversation transcript (most recent at the bottom):
        \(recent)\(topics)
        """
    }
}
