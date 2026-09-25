import Foundation

enum ChatScroll {
    /// Where the AI pane should scroll for the newest message: the question
    /// bubble right above an answer, so the question and the first line of the
    /// answer are read first. Scrolling to the *bottom* instead pushed the start
    /// of a long answer out of view while it was still being written.
    static func target(in messages: [ChatMessage]) -> UUID? {
        guard let last = messages.last else { return nil }
        if last.role == .assistant, messages.count >= 2 {
            let previous = messages[messages.count - 2]
            if previous.role == .user { return previous.id }
        }
        return last.id
    }
}
