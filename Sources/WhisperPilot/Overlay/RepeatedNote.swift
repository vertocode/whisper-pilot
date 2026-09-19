import Foundation

/// Stops the same system note from piling up when something keeps failing in a row.
enum RepeatedNote {
    private static let lookback = 6

    static func isRepeat(_ text: String, in messages: [ChatMessage]) -> Bool {
        messages.suffix(lookback).contains { $0.role == .system && $0.text == text }
    }
}
