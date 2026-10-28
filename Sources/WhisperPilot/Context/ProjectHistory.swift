import Foundation

/// Builds the "earlier sessions in this project" block for the AI prompt.
enum ProjectHistory {
    struct Entry: Sendable, Equatable {
        let title: String
        let date: Date
        let text: String
    }

    /// Characters of transcript used for a session that has no summary yet.
    static let fallbackCharacters = 1_500
    /// Not worth adding a last entry if less than this much room is left.
    private static let minimumTail = 300

    /// Entries must already be newest first. Whole entries are added until the budget runs
    /// out, so the most recent sessions always make it in; the last one that fits may be cut.
    static func block(entries: [Entry], budget: Int) -> String? {
        var parts: [String] = []
        var used = 0
        for entry in entries {
            let header = "### \(entry.title) (\(dateFormatter.string(from: entry.date)))\n"
            let separator = parts.isEmpty ? 0 : 2
            let room = budget - used - separator - header.count
            guard room >= minimumTail || (room > 0 && entry.text.count <= room) else { break }
            let body = entry.text.count <= room
                ? entry.text
                : String(entry.text.prefix(room - 1)) + "…"
            let part = header + body
            parts.append(part)
            used += part.count + separator
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// The end of a transcript, as plain "Me:/Other:" lines, for sessions without a summary.
    static func transcriptFallback(_ transcriptMarkdown: String) -> String {
        let plain = SessionTitler.plainTranscript(transcriptMarkdown)
        guard plain.count > fallbackCharacters else { return plain }
        return "…" + plain.suffix(fallbackCharacters)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
