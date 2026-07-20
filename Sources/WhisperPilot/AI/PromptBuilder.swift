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

    /// Triggered by the "Summary" button. Asks the model to produce a self-
    /// contained recap of the meeting using the full transcript + AI chat as
    /// context. Style is ignored — the directive overrides it so a user with
    /// Concise selected still gets a usable summary instead of a one-liner.
    static func buildSummary(context: ConversationSnapshot, history: [ChatTurn]) -> Prompt {
        let system = """
        You are summarizing a meeting that's still in progress. Use the live transcript and \
        prior AI chat below as your only source of truth — do not invent anything that isn't \
        in the conversation.

        Produce a clear recap covering:
        - What was discussed (1–3 sentences of context).
        - Key points or decisions raised.
        - Any open questions or unresolved topics.

        Use short bullet groups under brief headings, or plain prose if the content is small. \
        Keep it readable in under a minute. If the transcript is empty or only contains small \
        talk, say so in one short line instead of padding.
        """
        return Prompt(
            systemInstruction: system,
            context: contextBlock(transcript: context, history: history),
            question: "Summarize the meeting so far based on the transcript and AI chat above.",
            // .detailed framing matches the directive's expectation of a multi-section reply.
            style: .detailed
        )
    }

    /// Triggered by the "Action items" button. Extracts commitments / TODOs
    /// from the transcript + AI chat. If genuinely none, the model is told to
    /// say so explicitly rather than fabricate placeholder items.
    static func buildActionItems(context: ConversationSnapshot, history: [ChatTurn]) -> Prompt {
        let system = """
        You are extracting action items from a meeting that's still in progress. Use the live \
        transcript and prior AI chat below as your only source of truth — do not fabricate \
        items, and do not infer commitments that weren't actually expressed.

        An action item is anything someone committed to do, was asked to do, or clearly needs \
        to do as a result of this conversation. Look for:
        - Explicit commitments: "I'll send the doc", "I'll review the PR by Friday".
        - Requests / assignments: "can you take a look at this", "Hector should ping the team".
        - Clear follow-ups: "we need to schedule a sync about X", "let's double-check Y".

        For each action item, list:
        - Who owns it (use the name if it appears in the transcript; otherwise "Me" or "Other").
        - What needs to be done (one short sentence).
        - When it's due, only if a deadline was actually mentioned.

        Format as a short numbered list, one item per line.

        If you genuinely cannot find any action items in the transcript, respond with exactly \
        this single line and nothing else:
        "I analyzed the entire transcript but found no pending action items."
        """
        return Prompt(
            systemInstruction: system,
            context: contextBlock(transcript: context, history: history),
            question: "List the pending action items from the meeting so far.",
            style: .detailed
        )
    }

    /// Triggered by the "answer what's on screen" global shortcut (⌘⇧A). A
    /// screenshot of the user's current display is attached to this prompt (set
    /// by the coordinator). The model reads the screen and answers whatever
    /// question is visible — multiple-choice or free text — concisely, the way a
    /// person glancing over the user's shoulder would. The live transcript / chat
    /// are still passed as background in case the on-screen question references
    /// the meeting, but the screenshot is the primary source of truth.
    static func buildAnswerScreen(context: ConversationSnapshot, history: [ChatTurn], style: ResponseStyle) -> Prompt {
        let system = """
        You are an ambient real-time copilot. Attached to this message is a screenshot of \
        the user's current screen. Read it and respond based on what is visible. The user \
        triggered you with a keyboard shortcut and cannot type a question — the screen IS \
        the question.

        Decide which case you're in and answer accordingly:

        1. MULTIPLE-CHOICE QUESTION (options labeled A/B/C/D, 1/2/3/4, etc.):
           Reply in exactly this shape: `Answer is "A" because <one short reason>.`
           Use the option's own label (the letter or number shown on screen). Give a single \
           brief clause of reasoning — no restating the whole question, no listing the other \
           options.

        2. OPEN / TEXT QUESTION (a question with no preset options):
           Answer it directly the way a knowledgeable person would, in 1–3 sentences. Lead \
           with the answer. Be brief but complete enough to actually be useful. No preamble, \
           no "great question", no sign-off.

        3. NO QUESTION ON SCREEN:
           Briefly say what you can see, then offer to help. Use this shape: \
           `No question detected, but I can see <a short description of what's on screen>. \
           How can I help you with that?`

        Never say "as an AI" or "I'd be happy to help". Never describe the screenshot in \
        detail unless you're in case 3. If the screen text is too blurry or cropped to read \
        the question, say so in one line and ask the user to bring the question fully into view.

        Style: \(style.rawValue) — \(style.description)
        """
        return Prompt(
            systemInstruction: system,
            context: contextBlock(transcript: context, history: history),
            question: "Read my screen and answer the question shown, following the rules above.",
            style: style
        )
    }

    // MARK: - Context budgets
    //
    // Per-section character caps (~4 chars ≈ 1 token). Without them a resumed
    // hours-long session pastes the *entire* transcript.md + chat.md into every
    // single trigger, and context files add up to 200 KB each — easy request-size
    // 400s on Gemini's free tier and uncontrolled per-call spend on Claude.
    // User-attached context keeps its head (documents front-load what they are);
    // transcripts and chat keep their tail (the recent end is what matters live).

    static let contextFileBudget = 16_000
    static let priorTranscriptBudget = 20_000
    static let priorChatBudget = 10_000

    /// Keeps the first `limit` characters, marking the cut.
    static func clampHead(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return text.prefix(limit) + "\n[… truncated — content continues but was cut to fit the prompt budget …]"
    }

    /// Keeps the last `limit` characters, marking the cut.
    static func clampTail(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return "[… earlier content truncated to fit the prompt budget …]\n" + text.suffix(limit)
    }

    private static func contextBlock(transcript: ConversationSnapshot, history: [ChatTurn]) -> String {
        var sections: [String] = []

        // Global context (applies to every session) goes first as the broadest
        // background, then session context (specific to this conversation) layers
        // on top. Both are explicitly user-attached, so the model should treat them
        // as authoritative when answering things like "based on my notes" / "what
        // does the attached file say about X".
        if let globalContext = transcript.globalContextBlock {
            sections.append("Global context provided by the user (applies to every session):\n\(clampHead(globalContext, to: contextFileBudget))")
        }
        if let sessionContext = transcript.sessionContextBlock {
            sections.append("Session context provided by the user (specific to this session):\n\(clampHead(sessionContext, to: contextFileBudget))")
        }

        if let priorTranscript = transcript.priorTranscriptMarkdown {
            sections.append("Prior session transcript (resumed):\n\(clampTail(priorTranscript, to: priorTranscriptBudget))")
        }
        if let priorChat = transcript.priorChatMarkdown {
            sections.append("Prior session AI chat (resumed):\n\(clampTail(priorChat, to: priorChatBudget))")
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
