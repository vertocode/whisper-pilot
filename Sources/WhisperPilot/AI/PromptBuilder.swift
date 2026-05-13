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

    /// Triggered when the user types a prompt in the composer. The transcript AND the prior
    /// chat are both included so multi-turn references ("translate that", "explain more",
    /// "what did they say about X") resolve naturally.
    ///
    /// When `withScreenshot` is true, the system instruction tells the model that an image
    /// of the user's current screen accompanies the prompt. The actual image bytes are
    /// attached separately on the `Prompt` (set by the coordinator after a successful
    /// `SCScreenshotManager` capture).
    static func buildUserQuery(
        context: ConversationSnapshot,
        history: [ChatTurn],
        query: String,
        style: ResponseStyle,
        withScreenshot: Bool = false
    ) -> Prompt {
        var system = """
        You are an ambient real-time copilot. The user has typed a question or instruction \
        for you. Use the provided live transcript and the prior chat as context. If the user \
        references "they", "that", or "what was said", interpret it against the transcript or \
        the most recent assistant turn. Be direct.

        Style: \(style.rawValue) — \(style.description)
        """
        if withScreenshot {
            system += "\n\nAttached to this message is a screenshot of the user's current screen. " +
                "Treat it as primary visual context for their question."
        }
        return Prompt(
            systemInstruction: system,
            context: contextBlock(transcript: context, history: history),
            question: query,
            style: style
        )
    }

    /// Triggered by the "Help AI" button. The user thinks there's an unanswered question
    /// in the recent transcript that the auto-detector missed. We hand the model the
    /// same full context as a normal user query but instruct it to *find* the question
    /// itself rather than receiving one pre-extracted from the transcript.
    static func buildHelpAI(context: ConversationSnapshot, history: [ChatTurn], style: ResponseStyle) -> Prompt {
        let system = """
        You are an ambient real-time copilot. The user pressed "Help AI" because they think \
        there's an unanswered question in the recent transcript that they could use help with.

        Your job:
        1. Find the most recent question directed at the user in the live meeting transcript \
           below. Lines from "Other" are the most common source. The question may not end \
           with a question mark — recognize implicit asks ("walk me through...", "tell me \
           about...", "so why did you...").
        2. Answer that question concisely, using the full conversation as context.
        3. If you genuinely cannot find a question, say so in one short line and instead \
           offer a brief summary of what was just discussed or a useful follow-up the user \
           could raise.

        Lead with the answer. Do not preface with "I found the question:" — the user already \
        sees, via a separate UI element, that they triggered this. Just answer.

        Style: \(style.rawValue) — \(style.description)
        """
        return Prompt(
            systemInstruction: system,
            context: contextBlock(transcript: context, history: history),
            question: "Identify and answer the most recent unanswered question in the transcript.",
            style: style
        )
    }

    private static func contextBlock(transcript: ConversationSnapshot, history: [ChatTurn]) -> String {
        var sections: [String] = []

        // Global context (applies to every session) goes first as the broadest
        // background, then session context (specific to this conversation) layers
        // on top. Both are explicitly user-attached, so the model should treat them
        // as authoritative when answering things like "based on my notes" / "what
        // does the attached file say about X".
        if let globalContext = transcript.globalContextBlock {
            sections.append("Global context provided by the user (applies to every session):\n\(globalContext)")
        }
        if let sessionContext = transcript.sessionContextBlock {
            sections.append("Session context provided by the user (specific to this session):\n\(sessionContext)")
        }

        if let priorTranscript = transcript.priorTranscriptMarkdown {
            sections.append("Prior session transcript (resumed):\n\(priorTranscript)")
        }
        if let priorChat = transcript.priorChatMarkdown {
            sections.append("Prior session AI chat (resumed):\n\(priorChat)")
        }

        let recent = transcript.recentLines.suffix(20).joined(separator: "\n")
        if !recent.isEmpty {
            sections.append("Live meeting transcript (most recent at the bottom):\n\(recent)")
        }
        if !transcript.topics.isEmpty {
            sections.append("Topics so far: \(transcript.topics.joined(separator: ", "))")
        }
        if !history.isEmpty {
            let formatted = history.suffix(10).map { turn in
                let label = turn.role == .user ? "User" : "You (assistant)"
                return "\(label): \(turn.text)"
            }.joined(separator: "\n")
            sections.append("Prior chat in this session (most recent at the bottom):\n\(formatted)")
        }

        return sections.joined(separator: "\n\n")
    }
}
