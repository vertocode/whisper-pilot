import Foundation

/// Heuristic scorer for whether a finalized transcript segment is a question that warrants
/// proactive AI assistance. v1 is intentionally rule-based and brittle — it's the easiest piece
/// of the app to A/B test, and a learned classifier can replace it behind the same surface.
struct QuestionDetector: Sendable {
    func score(_ segment: TranscriptSegment) -> Double {
        // Score channel-agnostically. The decision of *whether* to act on a
        // detected question (on Other only, on Me only, both, or neither) now
        // lives in SettingsStore via the per-channel auto-detect toggles. This
        // detector just answers "does this text look like a question?".
        //
        // One transcript line often holds several sentences, e.g. "Thanks for
        // joining. ... could you walk me through your last project?". Scoring the whole
        // line buried the question under the small talk before it, so each sentence
        // is scored on its own and the best one wins.
        Self.realSentences(in: segment.text).map(Self.scoreSentence).max() ?? 0
    }

    /// Looser than `score`: true when a line has a question word or phrase anywhere.
    /// Those lines are worth a quick yes/no check with the AI, because speech
    /// recognition often loses the "?" and the heuristics miss oddly phrased questions.
    func mightBeQuestion(_ segment: TranscriptSegment) -> Bool {
        let sentences = Self.realSentences(in: segment.text)
        let words = sentences.flatMap(Self.words)
        guard words.count >= 4 else { return false }
        if sentences.contains(where: { $0.contains("?") }) { return true }
        let padded = " " + words.joined(separator: " ") + " "
        return Self.questionCues.contains { padded.contains(" \($0) ") }
    }

    /// Sentences minus small talk. "How are you?" and "Can you hear me?" are
    /// questions, but answering them with the AI is noise, and firing on them
    /// would start the cooldown right before the real question.
    private static func realSentences(in text: String) -> [String] {
        sentences(in: text).filter { !isSmallTalk($0) }
    }

    /// The whole sentence has to be small talk: "hi Sam, how are you doing today"
    /// is, "how are you handling state in that app" is not.
    private static func isSmallTalk(_ sentence: String) -> Bool {
        var words = words(in: sentence)
        while let last = words.last, smallTalkTrailers.contains(last) { words.removeLast() }
        let joined = " " + words.joined(separator: " ")
        return smallTalk.contains { phrase in
            let phraseWords = phrase.split(separator: " ").count
            return joined.hasSuffix(" " + phrase) && words.count <= phraseWords + 3
        }
    }

    private static let smallTalkTrailers: Set<String> = [
        "today", "doing", "guys", "everyone", "all", "there", "now", "okay", "ok", "so", "well"
    ]

    /// Lowercased letter runs, so "how's" becomes "how", "s".
    private static func words(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
    }

    /// Written the way `words(in:)` splits them, e.g. "how s it going".
    private static let smallTalk: [String] = [
        "how are you", "how s it going", "how is it going",
        "how have you been", "how was your weekend", "how was your day",
        "how s your day", "how is your day",
        "can you hear me", "can you hear us", "can everyone hear me",
        "can you see my screen", "can you see me", "can you see it",
        "are you there", "did i lose you", "am i audible", "is my audio",
        "nice to meet you", "good to meet you", "are you ready"
    ]

    private static let questionCues: [String] = [
        "what", "how", "why", "which", "where", "when", "who",
        "can you", "could you", "would you", "will you", "do you", "did you",
        "have you", "are you", "were you", "question", "curious", "wondering",
        "tell me", "tell us", "walk me", "walk us", "explain", "describe",
        "share", "thoughts", "talk about"
    ]

    private static func scoreSentence(_ raw: String) -> Double {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 6 else { return 0 }
        let lower = text.lowercased()
        let hasQuestionMark = text.hasSuffix("?")
        // Conversational openers like "okay, so why did you choose..." kept the
        // interrogative word *off* the front, so neither the starter nor the modal-lead
        // bonus fired. Strip leading filler / connector tokens before those checks so
        // the real signal isn't masked by a preamble.
        let cleaned = Self.strippingLeadingFillers(lower)

        var score = 0.0
        if hasQuestionMark { score += 0.50 }

        if Self.interrogativeStarters.contains(where: { cleaned.hasPrefix($0 + " ") }) {
            score += 0.35
        } else if Self.interrogativeStarters.contains(where: { lower.contains(" \($0) ") }) {
            // Soft signal — interrogative word appears somewhere mid-sentence after
            // a more complex preamble we didn't recognize. Weaker than a leading
            // "why ..." but still meaningful, especially combined with a question mark.
            // Kept below 0.20 so a rambly long input ending in "...what do you think?"
            // doesn't over-fire — the dedicated leading-strip branch above is where
            // legitimate "okay, so why did you..." cases score high.
            score += 0.15
        }
        if Self.modalLeads.contains(where: { cleaned.hasPrefix($0 + " ") }) {
            score += 0.5
        }

        if lower.contains(" you ") || lower.hasPrefix("you ") || lower.hasSuffix(" you") {
            score += 0.1
        }
        if lower.contains("your ") {
            score += 0.05
        }

        let words = lower.split(separator: " ").count
        if words < 4 { score -= 0.2 }
        if words > 30 { score -= 0.1 }

        // A clear question mark is strong enough to override the filler-start penalty.
        // Otherwise legitimate openers ("Yeah so what do you think?") get punished for
        // their preamble and silently fail the 0.6 threshold.
        if !hasQuestionMark, Self.fillerStarts.contains(where: { lower.hasPrefix($0) }) {
            score -= 0.15
        }

        if Self.isClearQuestion(cleaned: cleaned, words: words, hasQuestionMark: hasQuestionMark) {
            score = max(score, clearQuestionFloor)
        }

        return max(0, min(1, score))
    }

    /// Just above the trigger threshold, so any one clear signal is enough to fire.
    private static let clearQuestionFloor = 0.65

    /// Shapes that are a question on their own. Speech recognition often drops the
    /// "?", so the no-"?" shapes matter as much as the "?" itself. The word minimums
    /// keep tag questions ("right?") and half-said sentences ("tell me about") out.
    private static func isClearQuestion(cleaned: String, words: Int, hasQuestionMark: Bool) -> Bool {
        if hasQuestionMark, words >= 3 { return true }
        // "Tell me about your experience with Kotlin in production"
        if words >= 5, requestLeads.contains(where: { cleaned.hasPrefix($0 + " ") }) { return true }
        // "What would give the team confidence that you can ramp up fast"
        if words >= 4, interrogativeStarters.contains(where: { starter in
            questionVerbs.contains { cleaned.hasPrefix("\(starter) \($0) ") }
        }) { return true }
        // "Can you start the interview", "Do you have experience with Swift"
        if words >= 4, modalLeads.contains(where: { cleaned.hasPrefix($0 + " ") }) { return true }
        return false
    }

    /// Splits on ".", "?", "!", ":" or ";" followed by whitespace, keeping the
    /// punctuation. The colon lets "my main question is: what would..." score
    /// the part after the colon on its own.
    private static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var previous: Character?
        for char in text {
            if char.isWhitespace, let p = previous, ".?!:;".contains(p) {
                result.append(current)
                current = ""
            } else {
                current.append(char)
            }
            previous = char
        }
        result.append(current)
        return result
    }

    /// Repeatedly trims leading filler-or-connector tokens (with the punctuation /
    /// whitespace that follows them) until the next word is content-bearing. Lets the
    /// interrogative-starter check see "why did you ..." in inputs like
    /// "okay, so why did you choose ..." or "yeah but how come you ...".
    private static func strippingLeadingFillers(_ lower: String) -> String {
        var s = lower
        while true {
            var trimmed = false
            for token in Self.leadingTrimTokens {
                let prefix = token + " "
                if s.hasPrefix(prefix) {
                    s = String(s.dropFirst(prefix.count))
                    trimmed = true
                    break
                }
                let punctPrefix = token + ","
                if s.hasPrefix(punctPrefix) {
                    s = String(s.dropFirst(punctPrefix.count))
                        .trimmingCharacters(in: .whitespaces)
                    trimmed = true
                    break
                }
            }
            if !trimmed { break }
            s = s.trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    private static let interrogativeStarters: Set<String> = [
        "how", "what", "why", "when", "where", "which", "who", "whom"
    ]

    private static let modalLeads: Set<String> = [
        "can you", "could you", "would you", "do you", "did you",
        "have you", "are you", "is there", "is it", "should we",
        "will you", "were you", "was it", "have we", "do we",
        "tell me", "walk me", "explain"
    ]

    /// Ways an interviewer asks for an answer without phrasing it as a question.
    private static let requestLeads: [String] = [
        "tell me", "tell us", "walk me", "walk us", "talk me", "talk us",
        "explain", "describe", "give me an example", "give us an example",
        "share", "i'd love to hear", "i'd like to hear", "i'd love to know",
        "i'd like to know", "i want to know", "i'm curious"
    ]

    /// Words that, right after "what" / "how" / "why" / ..., make the sentence a
    /// question rather than a statement like "what I did was...".
    private static let questionVerbs: Set<String> = [
        "is", "are", "was", "were", "do", "does", "did", "would", "will", "can",
        "could", "should", "have", "has", "had", "made", "makes", "led",
        "long", "much", "many", "often", "come", "kind", "type", "sort"
    ]

    private static let fillerStarts: [String] = [
        "yeah", "yes", "no", "okay", "ok", "sure", "right", "uh", "um", "hmm"
    ]

    /// Fillers + light connectors that can appear before the real interrogative word.
    /// Includes the conjunctions ("so", "and", "but", "well") that frequently glue a
    /// filler onto the actual question.
    private static let leadingTrimTokens: [String] = [
        "yeah", "yes", "no", "okay", "ok", "sure", "right", "uh", "um", "hmm",
        "so", "and", "but", "well", "like", "i mean", "now", "alright", "all right"
    ]
}
