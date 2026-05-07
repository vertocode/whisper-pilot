import Foundation

enum PromptBuilder {
    static func build(context: ConversationSnapshot, question: String, style: ResponseStyle) -> Prompt {
        let system = """
        You are an ambient real-time copilot for a live conversation. The user cannot type to you. \
        They will hear or read what you produce while they are still talking. Be direct. Lead with the answer. \
        Never say "as an AI" or "I'd be happy to help". Match the requested style.

        Style: \(style.rawValue) — \(style.description)
        """

        let recent = context.recentLines.suffix(20).joined(separator: "\n")
        let topics = context.topics.isEmpty ? "" : "\nTopics so far: \(context.topics.joined(separator: ", "))"

        let contextBlock = """
        Recent conversation transcript (most recent at the bottom):
        \(recent)\(topics)
        """

        return Prompt(
            systemInstruction: system,
            context: contextBlock,
            question: question,
            style: style
        )
    }
}
