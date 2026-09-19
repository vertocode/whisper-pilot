import Foundation

/// Shortens an API error body for display in the overlay.
enum AIErrorBody {
    private static let maxLength = 200

    /// Prefers the `error.message` field both vendors use; otherwise the raw
    /// body, flattened to one line and cut short so a big HTML or JSON dump
    /// never lands in the chat.
    static func summary(_ body: String?) -> String? {
        guard let body else { return nil }
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return truncate(message)
        }
        let flat = body.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.isEmpty ? nil : truncate(flat)
    }

    private static func truncate(_ text: String) -> String {
        text.count > maxLength ? String(text.prefix(maxLength)) + "…" : text
    }
}
