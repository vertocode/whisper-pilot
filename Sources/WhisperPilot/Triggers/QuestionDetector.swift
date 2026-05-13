import Foundation

/// Heuristic scorer for whether a finalized transcript segment is a question that warrants
/// proactive AI assistance. v1 is intentionally rule-based and brittle — it's the easiest piece
/// of the app to A/B test, and a learned classifier can replace it behind the same surface.
struct QuestionDetector: Sendable {
    func score(_ segment: TranscriptSegment) -> Double {
        // Only the *other party* asks us questions. Ignore mic channel.
        guard segment.channel == .system else { return 0 }

        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
            score += 0.45
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

        return max(0, min(1, score))
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
        "tell me", "walk me", "explain"
    ]

    private static let fillerStarts: [String] = [
        "yeah", "yes", "no", "okay", "ok", "sure", "right", "uh", "um", "hmm"
    ]

    /// Fillers + light connectors that can appear before the real interrogative word.
    /// Includes the conjunctions ("so", "and", "but", "well") that frequently glue a
    /// filler onto the actual question.
    private static let leadingTrimTokens: [String] = [
        "yeah", "yes", "no", "okay", "ok", "sure", "right", "uh", "um", "hmm",
        "so", "and", "but", "well", "like", "i mean"
    ]
}
