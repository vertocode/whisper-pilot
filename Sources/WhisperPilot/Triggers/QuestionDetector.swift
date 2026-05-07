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

        var score = 0.0
        if hasQuestionMark { score += 0.45 }

        if Self.interrogativeStarters.contains(where: { lower.hasPrefix($0 + " ") }) {
            score += 0.35
        }
        if Self.modalLeads.contains(where: { lower.hasPrefix($0 + " ") }) {
            score += 0.3
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

        if Self.fillerStarts.contains(where: { lower.hasPrefix($0) }) {
            score -= 0.15
        }

        return max(0, min(1, score))
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
}
