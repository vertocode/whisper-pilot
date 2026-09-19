import Foundation

/// What gets written to `chat.md` for an assistant reply.
enum AssistantTurnText {
    static let incompleteMarker = "(incomplete)"

    /// Returns nil when there is nothing worth saving. A reply that was cut off
    /// (error, cancel, token limit) keeps what the user saw, tagged so a resumed
    /// session doesn't mistake it for a finished answer.
    static func persisted(_ text: String, incomplete: Bool) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return incomplete ? "\(text)\n\n\(incompleteMarker)" : text
    }
}
