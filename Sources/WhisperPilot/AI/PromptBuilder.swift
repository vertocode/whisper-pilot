import Foundation

/// Lightweight Sendable view of a chat exchange to hand off across actor boundaries when
/// building a prompt. Keeps `PromptBuilder` free of dependencies on UI types.
struct ChatTurn: Sendable {
    enum Role: String, Sendable { case user, assistant }
    let role: Role
    let text: String
}

enum PromptBuilder {
    /// How every answer the user might say out loud should sound. Shared so the
    /// auto-detected, typed, Help AI, and on-screen paths all sound like the same person.
    static let speakingVoice = """
    Write the exact words the user will say out loud, in first person, the way a strong \
    candidate in a job interview or a good colleague in a meeting would answer.

    Honesty comes first. The user will say your words out loud, maybe in a job interview, \
    so a wrong fact can cost them:
    - Facts about the user come only from the user's notes and from what the user ("Me") \
    already said in the transcript. Never invent jobs, projects, years, tools, numbers, or \
    results. Don't fill gaps with plausible details either: no made-up metrics, outcomes, \
    team sizes, or technical specifics the notes don't mention. When the notes are thin, \
    give a shorter answer that stays with what they do say. This matters most for "walk \
    me through" and "tell me about a time" questions: tell the story only with the \
    details the notes give, and talk about how the user worked instead of adding events.
    - Some facts only the user can know: dates, trips, availability, start date, salary, \
    other interviews or offers, names of people they talked to, how they found the role. \
    If the notes and the transcript don't say, don't guess and don't answer yes or no for \
    them. Put the fact itself in square brackets for the user to fill in while they read, \
    like "In the next six months I have [trips and dates, or none]." Nothing outside the \
    brackets should state the fact, and no extra line like "I'm fully available" either. \
    When they offer options about the user's own life ("was it Anna or Ben?"), never \
    pick one. Reply with the blank, like "It was [name]."
    - If the notes don't cover a skill they ask about, say honestly that you haven't used it \
    yet, connect it to the closest real experience, and say how you would approach it.
    - Stay consistent with what the user already said in the transcript and with your \
    earlier answers in this chat. When the user said something different from the notes, \
    follow what the user said.

    How it should sound:
    - Clear, warm and professional, like a real person talking, not like a written document.
    - Simple, common English words and short sentences, so the user can read it aloud at a \
    glance. Say "use" instead of "leverage", "help" instead of "facilitate", "make sure" \
    instead of "ensure".
    - No slang or casual filler ("gonna", "kinda", "super", "awesome", "stuff", "that kind \
    of thing") and no buzzwords ("seamless", "robust", "synergy", "passionate", "cutting-edge").
    - Plain sentences with periods and commas. No dashes, semicolons, parentheses, headings, \
    bullet lists, or bold. Only include code if the question literally asks for code.
    - Start with the answer itself. For a yes or no question, start with yes or no. No \
    preamble or filler: no "Great question", no restating the question, no sign-off. Never \
    say "as an AI" or "I'd be happy to help".
    - Answer only what they asked. Don't bring in other topics or add a closing line about \
    being flexible, excited, or committed.
    - Keep it short: two to four sentences for most questions, and at most six short \
    sentences in one paragraph for "tell me about a time" or "walk me through" questions. \
    If they ask for more detail, go a bit longer, but keep it under a minute of speaking.
    - One real detail from the notes (a project, a tool, a number) is better than several \
    general claims.
    - When you're sure, say it plainly. When you're not fully sure, hedge briefly the way a \
    person would ("I believe it's X"). Don't hedge answers you're sure about.
    - Reply in the same language the question was asked in.
    """

    /// The transcript is machine-made, and the prompts need the model to read through
    /// its mistakes instead of answering them literally.
    static let transcriptCaveat = """
    The transcript comes from live speech recognition. Words can be misheard (names and \
    technical terms most of all), punctuation can be missing or misplaced, one sentence can \
    be split across lines, and lines from the two speakers can overlap. Use the lines \
    around it and the user's notes to work out what was really said.
    """

    /// Yes/no check for transcript lines the question detector isn't sure about.
    static func buildQuestionCheck(_ text: String) -> String {
        """
        Below is a line from a live speech-to-text transcript of a conversation, usually a \
        job interview. Punctuation may be missing or wrong, and the line may be cut off. \
        Does the speaker ask the listener something they are expected to answer now? That \
        includes short yes or no questions, questions about logistics like dates or salary, \
        and requests like "tell me about...", "walk me through...", "my question is...". \
        Greetings and small talk ("how are you", "how was your weekend"), checks like "can \
        you hear me", and rhetorical questions do not count. Reply with only YES or NO.

        Line: \(text)
        """
    }

    static func parseQuestionCheck(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("YES")
    }

    /// Triggered by the question detector when someone in the meeting asks something.
    static func build(context: ConversationSnapshot, history: [ChatTurn], question: String, style: ResponseStyle) -> Prompt {
        let system = """
        You are a real-time copilot for a live conversation. Someone in the meeting just asked \
        the user a question, and the user is about to answer it out loud. They can't type to \
        you and will glance at your reply while they talk, so lead with the answer.

        \(transcriptCaveat) The question below was picked up automatically, so it may be cut \
        off, or start with the end of an earlier sentence. Answer what was really asked, \
        using the latest lines from "Other". If they asked several things at once, answer \
        all of them in order, in one reply.

        If they're asking whether the user has any questions for them (common at the end of \
        an interview), reply with two or three short questions the user could ask, based on \
        the role, team or company in the user's notes and what came up in the conversation.

        \(speakingVoice)

        Style: \(style.rawValue) — \(style.description)
        """
        return Prompt(
            systemInstruction: system,
            context: contextBlock(transcript: context, history: history),
            stableContext: stableContextBlock(transcript: context),
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
        You are a real-time copilot for a live conversation. The user typed a question or \
        instruction for you. Use the live transcript and the prior chat as context. If they \
        say "they", "that", or "what was said", read it against the transcript or your most \
        recent reply. \(transcriptCaveat)

        If they want help answering something in the meeting (or ask for more detail on your \
        last answer), follow the speaking voice below. If it's a task just for them, like \
        translating, explaining a term, or checking what someone said, do it directly and \
        briefly in a friendly, plain tone.

        \(speakingVoice)

        Style: \(style.rawValue) — \(style.description)
        """
        if withScreenshot {
            system += "\n\nAttached to this message is a screenshot of the user's current screen. " +
                "Treat it as primary visual context for their question."
        }
        return Prompt(
            systemInstruction: system,
            context: contextBlock(transcript: context, history: history),
            stableContext: stableContextBlock(transcript: context),
            question: query,
            style: style
        )
    }

    /// What the app already put on screen for the interviewer's questions, so Help AI
    /// can tell a question that is already handled from a new one.
    private static func handledBlock(_ handled: [String]) -> String {
        guard !handled.isEmpty else { return "Already shown to the user: nothing yet." }
        return "Already shown to the user (questions the app detected and answered or is " +
            "answering, and replies it gave):\n" + handled.map { "- \($0)" }.joined(separator: "\n")
    }

    /// Silent first step of "Help AI". Nothing from this call is shown; it only decides
    /// whether the click should produce an answer or be ignored.
    static func buildHelpAICheck(context: ConversationSnapshot, history: [ChatTurn], handled: [String]) -> Prompt {
        let system = """
        The user is in a live conversation, usually a job interview, and pressed a button \
        asking for help answering. Look at what "Other" said most recently in the transcript \
        below. Only the latest turn matters: the last question, or the last few questions \
        if they were asked together. A question may have no question mark and may be cut \
        off. \(transcriptCaveat)

        \(handledBlock(handled))

        Reply with exactly one word:
        - SKIP if there is no question directed at the user in Other's latest turn, or if \
        every question there is already covered by what was shown to the user.
        - NEW if Other's latest turn has a question that was not covered yet.
        """
        return Prompt(
            systemInstruction: system,
            context: contextBlock(transcript: context, history: history),
            stableContext: stableContextBlock(transcript: context),
            question: "Reply NEW or SKIP.",
            style: .concise
        )
    }

    static func parseHelpAICheck(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("NEW")
    }

    /// Triggered by the "Help AI" button, after the silent check found a question that
    /// the auto-detector did not answer. The reply is only the words the user reads out.
    static func buildHelpAI(context: ConversationSnapshot, history: [ChatTurn], handled: [String], style: ResponseStyle) -> Prompt {
        let system = """
        The user pressed "Help AI" during a live conversation, usually a job interview. \
        Take what "Other" said most recently in the transcript below: the last question, or \
        the last few if they were asked together. It may have no question mark, and it may \
        be cut off. \(transcriptCaveat) Do not answer questions that were already handled.

        \(handledBlock(handled))

        Reply with ONLY the words the user should say out loud to answer it, as if you were \
        the user being interviewed. First person. Nothing before it and nothing after it: \
        never mention who asked, never describe or repeat the question ("X is asking...", \
        "It sounds like..."), no heading, no label, no notes, no sign-off. If there are \
        several questions, answer them in order in one flowing reply.

        \(speakingVoice)

        Style: \(style.rawValue) — \(style.description)
        """
        return Prompt(
            systemInstruction: system,
            context: contextBlock(transcript: context, history: history),
            stableContext: stableContextBlock(transcript: context),
            question: "Answer the latest question(s) from Other. Output only the words I should say.",
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

        Write it like a quick recap you'd send a teammate: short bullet groups under brief \
        headings, or plain prose if there isn't much. Keep it readable in under a minute. If the transcript is empty or only contains small \
        talk, say so in one short line instead of padding.
        """
        return Prompt(
            systemInstruction: system,
            context: contextBlock(transcript: context, history: history),
            stableContext: stableContextBlock(transcript: context),
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
            stableContext: stableContextBlock(transcript: context),
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
        You are a real-time copilot. Attached to this message is a screenshot of \
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
           Answer it the way the user would say it out loud, following the speaking voice \
        below. Lead with the answer, 1–3 sentences.

        3. NO QUESTION ON SCREEN:
           Briefly say what you can see, then offer to help. Use this shape: \
        `No question detected, but I can see <a short description of what's on screen>. \
        How can I help you with that?`

        Never say "as an AI" or "I'd be happy to help". Never describe the screenshot in \
        detail unless you're in case 3. If the screen text is too blurry or cropped to read \
        the question, say so in one line and ask the user to bring the question fully into view.

        \(speakingVoice)

        Style: \(style.rawValue) — \(style.description)
        """
        return Prompt(
            systemInstruction: system,
            context: contextBlock(transcript: context, history: history),
            stableContext: stableContextBlock(transcript: context),
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
    /// About 30 minutes of two-way conversation, so the AI remembers what the user
    /// said early in a long interview.
    static let liveTranscriptBudget = 32_000

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

    /// The part of the context that stays the same from one call to the next in a
    /// session (the user's notes and files, and a resumed session's history). It goes
    /// first so Claude can cache it and skip re-reading it on every question.
    private static func stableContextBlock(transcript: ConversationSnapshot) -> String {
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
        return sections.joined(separator: "\n\n")
    }

    /// The whole prompt context: the stable part first, then what changes every call.
    private static func contextBlock(transcript: ConversationSnapshot, history: [ChatTurn]) -> String {
        var sections: [String] = []
        let stable = stableContextBlock(transcript: transcript)
        if !stable.isEmpty { sections.append(stable) }

        let recent = clampTail(transcript.recentLines.joined(separator: "\n"), to: liveTranscriptBudget)
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
