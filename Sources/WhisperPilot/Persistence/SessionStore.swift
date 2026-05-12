import AppKit
import Foundation
import OSLog

/// A session lives on disk as a folder under `~/Library/Application Support/<bundle-id>/sessions/`.
/// Folder layout:
///   <slug>-YYYY-MM-DD-HH-mm/
///     metadata.json   — display name, created/used timestamps
///     transcript.md   — appended live; one line per finalized transcript segment
///     chat.md         — appended live; one heading + body per chat turn
///
/// We deliberately use plain markdown so the user can browse, grep, share, and version-control
/// their session content without our app being involved.
struct SessionID: Hashable, Sendable, Codable {
    let folderName: String
}

struct SessionMeta: Identifiable, Sendable, Codable, Equatable {
    var folderName: String
    var displayName: String
    var createdAt: Date
    var lastUsedAt: Date
    /// Live counts maintained on every list refresh — not persisted.
    var transcriptLineCount: Int = 0
    var chatTurnCount: Int = 0

    var id: SessionID { SessionID(folderName: folderName) }

    private enum CodingKeys: String, CodingKey {
        case folderName, displayName, createdAt, lastUsedAt
    }
}

actor SessionStore {
    static let shared = SessionStore()

    let baseURL: URL
    private let log = Logger(subsystem: "com.whisperpilot.app", category: "SessionStore")

    init() {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.whisperpilot.app"
        let appSupport: URL
        if let url = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            appSupport = url
        } else {
            appSupport = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        }
        self.baseURL = appSupport.appendingPathComponent(bundleId).appendingPathComponent("sessions")
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    nonisolated var rootURL: URL { baseURL }

    func sessionFolder(for id: SessionID) -> URL {
        baseURL.appendingPathComponent(id.folderName)
    }

    func listSessions() -> [SessionMeta] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: baseURL.path)) ?? []
        var metas: [SessionMeta] = []
        for name in names {
            let folder = baseURL.appendingPathComponent(name)
            let metaURL = folder.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: metaURL),
                  var meta = try? makeDecoder().decode(SessionMeta.self, from: data) else {
                continue
            }
            meta.transcriptLineCount = countTranscriptLines(at: folder)
            meta.chatTurnCount = countChatTurns(at: folder)
            metas.append(meta)
        }
        metas.sort { $0.lastUsedAt > $1.lastUsedAt }
        return metas
    }

    func createSession(name: String?) throws -> SessionMeta {
        let now = Date()
        let cleaned = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = cleaned.isEmpty ? "Untitled session" : cleaned
        let slug = cleaned.isEmpty ? "session" : cleaned.slugify()
        let dateString = Self.dateFormatter.string(from: now)
        let folderName = "\(slug)-\(dateString)"
        let folder = baseURL.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let meta = SessionMeta(
            folderName: folderName,
            displayName: displayName,
            createdAt: now,
            lastUsedAt: now
        )
        try writeMetadata(meta, to: folder)
        // Seed empty md files so users can open the folder right away and see it.
        try? "# Transcript\n\n_Captured live by Whisper Pilot._\n\n".write(
            to: folder.appendingPathComponent("transcript.md"),
            atomically: true,
            encoding: .utf8
        )
        try? "# Chat\n\n_Conversation between you and the AI._\n\n".write(
            to: folder.appendingPathComponent("chat.md"),
            atomically: true,
            encoding: .utf8
        )
        log.info("Created session at \(folder.path, privacy: .public)")
        return meta
    }

    func renameSession(_ id: SessionID, to newName: String) throws -> SessionMeta? {
        let folder = sessionFolder(for: id)
        let metaURL = folder.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metaURL),
              var meta = try? makeDecoder().decode(SessionMeta.self, from: data) else { return nil }
        meta.displayName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        try writeMetadata(meta, to: folder)
        return meta
    }

    func deleteSession(_ id: SessionID) throws {
        try FileManager.default.removeItem(at: sessionFolder(for: id))
    }

    func touch(_ id: SessionID) {
        let folder = sessionFolder(for: id)
        let metaURL = folder.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metaURL),
              var meta = try? makeDecoder().decode(SessionMeta.self, from: data) else { return }
        meta.lastUsedAt = Date()
        try? writeMetadata(meta, to: folder)
    }

    // MARK: - Append (called from coordinator on every finalized event)

    func appendTranscriptLine(channel: AudioChannel, text: String, at: Date, to id: SessionID) {
        let speaker = channel == .system ? "Other" : "Me"
        let timestamp = Self.timeFormatter.string(from: at)
        let line = "**\(speaker)** [\(timestamp)] \(text)"
        appendToFile(line + "\n\n", at: sessionFolder(for: id).appendingPathComponent("transcript.md"))
        touch(id)
    }

    func appendChatTurn(role: String, text: String, at: Date, to id: SessionID) {
        let timestamp = Self.timeFormatter.string(from: at)
        let block = "## \(role) [\(timestamp)]\n\n\(text)\n"
        appendToFile(block + "\n", at: sessionFolder(for: id).appendingPathComponent("chat.md"))
        touch(id)
    }

    // MARK: - Load on resume

    /// Returns the raw markdown contents so the coordinator can hand them to the AI as
    /// prior context. We deliberately keep the format human-readable rather than parsing
    /// back into structured types — the model handles the markdown fine, and any reader
    /// (you, a future contributor, an external tool) can work with the same text.
    func loadTranscriptMarkdown(_ id: SessionID) -> String {
        let url = sessionFolder(for: id).appendingPathComponent("transcript.md")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func loadChatMarkdown(_ id: SessionID) -> String {
        let url = sessionFolder(for: id).appendingPathComponent("chat.md")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Parses `transcript.md` back into `TranscriptSegment`s so the overlay can rehydrate
    /// the live transcript lane when a session is resumed. Each persisted line
    /// (`**Me** [HH:MM:SS] text` / `**Other** [HH:MM:SS] text`) becomes one finalized
    /// segment. Anything that doesn't match (the header, blank lines) is ignored.
    func loadTranscriptSegments(_ id: SessionID) -> [TranscriptSegment] {
        Self.parseTranscriptMarkdown(loadTranscriptMarkdown(id))
    }

    /// Parses `chat.md` back into `ChatMessage`s so the overlay can rehydrate the chat
    /// lane on resume. Origin metadata isn't persisted on disk, so loaded turns default
    /// to `.userPrompt` — that just suppresses the "detected question" / "auto-send"
    /// badge, which makes sense for historical turns.
    func loadChatMessages(_ id: SessionID) -> [ChatMessage] {
        Self.parseChatMarkdown(loadChatMarkdown(id))
    }

    private static let transcriptLineRegex = #/^\*\*(?<speaker>Me|Other)\*\* \[(?<time>\d{2}:\d{2}:\d{2})\] (?<text>.+)$/#
    private static let chatHeaderRegex = #/^(?<role>You|Assistant|System) \[(?<time>\d{2}:\d{2}:\d{2})\]$/#

    private static func parseTranscriptMarkdown(_ markdown: String) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        let now = Date()
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let match = line.firstMatch(of: transcriptLineRegex) else { continue }
            let channel: AudioChannel = match.speaker == "Me" ? .microphone : .system
            let timestamp = parseTime(String(match.time)) ?? now
            segments.append(TranscriptSegment(
                id: UUID(),
                text: String(match.text),
                isFinal: true,
                channel: channel,
                startedAt: timestamp,
                updatedAt: timestamp
            ))
        }
        return segments
    }

    private static func parseChatMarkdown(_ markdown: String) -> [ChatMessage] {
        // `## ` always appears at the start of a turn block. Split on `\n## ` so the
        // first chunk is the file header (or empty) and every subsequent chunk starts
        // with `Role [HH:MM:SS]\n\nbody…`.
        let chunks = markdown.components(separatedBy: "\n## ")
        let now = Date()
        var messages: [ChatMessage] = []
        for chunk in chunks.dropFirst() {
            guard let newlineIdx = chunk.firstIndex(of: "\n") else { continue }
            let header = chunk[..<newlineIdx]
            guard let match = header.firstMatch(of: chatHeaderRegex) else { continue }
            let body = chunk[chunk.index(after: newlineIdx)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let timestamp = parseTime(String(match.time)) ?? now
            let role: ChatMessage.Role
            switch match.role {
            case "You": role = .user
            case "Assistant": role = .assistant
            default: role = .system
            }
            messages.append(ChatMessage(
                id: UUID(),
                role: role,
                origin: role == .system ? .system : .userPrompt,
                text: body,
                timestamp: timestamp,
                isStreaming: false,
                category: role == .system ? .general : .ai
            ))
        }
        return messages
    }

    /// Combines today's date with a `HH:MM:SS` timestamp. The on-disk format throws away
    /// the date, so this is only useful for relative ordering inside a session — good
    /// enough for the UI, which renders messages chronologically by array position.
    private static func parseTime(_ string: String) -> Date? {
        let parts = string.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = parts[0]
        components.minute = parts[1]
        components.second = parts[2]
        return Calendar.current.date(from: components)
    }

    // MARK: - Helpers

    private func writeMetadata(_ meta: SessionMeta, to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(meta)
        try data.write(to: folder.appendingPathComponent("metadata.json"))
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func appendToFile(_ text: String, at url: URL) {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try? text.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                if let data = text.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
            } catch {
                log.error("Append failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func countTranscriptLines(at folder: URL) -> Int {
        guard let s = try? String(contentsOf: folder.appendingPathComponent("transcript.md"), encoding: .utf8) else {
            return 0
        }
        return s.split(separator: "\n").filter { $0.hasPrefix("**") }.count
    }

    private func countChatTurns(at folder: URL) -> Int {
        guard let s = try? String(contentsOf: folder.appendingPathComponent("chat.md"), encoding: .utf8) else {
            return 0
        }
        return s.components(separatedBy: "\n## ").count - 1
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HH-mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

private extension String {
    func slugify() -> String {
        let lower = self.lowercased()
        let chars = lower.compactMap { c -> Character? in
            if c.isLetter || c.isNumber { return c }
            if c.isWhitespace || c == "-" || c == "_" { return "-" }
            return nil
        }
        var s = String(chars)
        while s.contains("--") { s = s.replacingOccurrences(of: "--", with: "-") }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if s.isEmpty { return "session" }
        return String(s.prefix(40))
    }
}
