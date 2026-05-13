import Foundation

/// A single file attached to the session's context library. We cache the text content
/// at attach time so prompt building stays fast and offline-friendly — the original
/// file on disk can move or vanish later without breaking the session.
struct ContextFile: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var filename: String
    /// User's original file URL string, kept only for display ("you attached ~/Docs/X.md").
    /// Not used for re-reading — `content` is the source of truth.
    var sourcePath: String
    var content: String
    var byteCount: Int
    var attachedAt: Date
}

/// User-supplied context for a session. Surfaces in every AI prompt (detected
/// questions, Help AI, composer) as a labeled block above the live transcript so
/// the model treats it as authoritative.
struct SessionContext: Codable, Sendable, Equatable {
    var customText: String = ""
    var files: [ContextFile] = []

    var isEmpty: Bool {
        customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty
    }

    /// Cap per-file content at ~200 KB so a stray multi-megabyte attachment doesn't
    /// torpedo a prompt. Truncates from the end with a trailing marker so it's clear
    /// the model didn't get the whole file.
    static let maxFileBytes = 200_000

    /// Markdown-style block injected into the AI prompt. Returns `nil` when there's
    /// nothing to add, so `PromptBuilder` can skip the section entirely.
    var promptBlock: String? {
        var sections: [String] = []
        let trimmed = customText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            sections.append("User notes:\n\(trimmed)")
        }
        for file in files {
            sections.append("Attached file `\(file.filename)`:\n```\n\(file.content)\n```")
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }
}
