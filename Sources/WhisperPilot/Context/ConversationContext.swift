import Foundation

struct ConversationSnapshot: Sendable {
    let recentLines: [String]
    let topics: [String]
    let entities: [String]
    /// Set when a session is resumed — markdown content from prior `transcript.md` and `chat.md`.
    /// `PromptBuilder` includes this as a separate section so the model knows it's older context.
    var priorTranscriptMarkdown: String? = nil
    var priorChatMarkdown: String? = nil
    /// User-supplied notes + attached files for this session, rendered as a single
    /// markdown block by `SessionContext.promptBlock`. The coordinator passes this
    /// in so it appears in every prompt (detected questions, Help AI, composer).
    var sessionContextBlock: String? = nil
    /// App-wide notes + files that apply to every session. Kept separate from
    /// `sessionContextBlock` so the prompt builder can label them distinctly and
    /// the model understands they're general background versus session-specific.
    var globalContextBlock: String? = nil
}

/// Rolling memory the LLM sees on every prompt. We keep the recent transcript verbatim and a small
/// set of extracted topics/entities so the model has continuity across turns without us re-sending
/// the whole transcript.
actor ConversationContext {
    /// One line per finalized utterance. Keyed by `id` so a second isFinal for
    /// the same segment (e.g., the natural SFSpeech final following our
    /// synthesized one, or a pre-prompt flush followed by a VAD-end cycle)
    /// updates the existing line in place rather than appending a duplicate.
    private struct Line {
        let id: UUID
        let channel: AudioChannel
        var text: String
        var at: Date
    }
    private var lines: [Line] = []
    private var topics = OrderedSet<String>(maxSize: 24)
    private var entities = OrderedSet<String>(maxSize: 32)
    private let retentionSeconds: TimeInterval = 300

    private let extractor = TopicExtractor()

    func absorb(_ update: TranscriptUpdate) {
        guard update.isFinal, !update.text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if let idx = lines.firstIndex(where: { $0.id == update.id }) {
            // Containment-guarded: multiple ids can map onto one merged or
            // rolled-up line; a fragment's re-final must not clobber it.
            if let mergedText = TranscriptDedup.merged(previous: lines[idx].text, incoming: update.text) {
                lines[idx].text = mergedText
            }
            lines[idx].at = update.timestamp
        } else if let lastIdx = lines.lastIndex(where: { $0.channel == update.channel }),
                  update.timestamp.timeIntervalSince(lines[lastIdx].at) <= TranscriptDedup.mergeWindowSeconds,
                  let mergedText = TranscriptDedup.merged(previous: lines[lastIdx].text, incoming: update.text) {
            // Same containment-merge as `TranscriptBuffer.applyFinal`: the
            // recognizer finalized one utterance twice under different ids
            // (synthetic pre-flush + natural final, or replay overlap). Keep the
            // model's view aligned with the on-screen transcript — without this
            // the prompt shows the utterance twice.
            lines[lastIdx].text = mergedText
            lines[lastIdx].at = update.timestamp
        } else if let lastIdx = lines.lastIndex(where: { $0.channel == update.channel }),
                  TranscriptDedup.shouldRollUp(
                      previousText: lines[lastIdx].text,
                      previousAt: lines[lastIdx].at,
                      incomingText: update.text,
                      incomingAt: update.timestamp
                  ) {
            // Continuation of the same speaker turn — join it, mirroring the
            // display buffer's roll-up.
            lines[lastIdx].text = TranscriptDedup.rolledUp(previousText: lines[lastIdx].text, incomingText: update.text)
            lines[lastIdx].at = update.timestamp
        } else {
            lines.append(Line(id: update.id, channel: update.channel, text: update.text, at: update.timestamp))
        }
        prune()

        let extracted = extractor.extract(from: update.text)
        for keyword in extracted.topics {
            topics.insert(keyword)
        }
        for entity in extracted.entities {
            entities.insert(entity)
        }
    }

    func snapshot() -> ConversationSnapshot {
        let formatted = lines.map { line -> String in
            let speaker = line.channel == .system ? "Other" : "Me"
            return "\(speaker): \(line.text)"
        }
        return ConversationSnapshot(
            recentLines: formatted,
            topics: topics.values,
            entities: entities.values
        )
    }

    func reset() {
        lines.removeAll()
        topics.clear()
        entities.clear()
    }

    /// Markdown loaded on session resume. Surfaced in the prompt context but kept separate
    /// from the live transcript so the live lane stays clean.
    private var priorTranscriptMarkdown: String?
    private var priorChatMarkdown: String?

    func seedFromMarkdown(transcript: String, chat: String) {
        lines.removeAll()
        topics.clear()
        entities.clear()
        let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = chat.trimmingCharacters(in: .whitespacesAndNewlines)
        priorTranscriptMarkdown = t.isEmpty ? nil : t
        priorChatMarkdown = c.isEmpty ? nil : c
    }

    func snapshotWithPrior() -> ConversationSnapshot {
        var snap = snapshot()
        snap.priorTranscriptMarkdown = priorTranscriptMarkdown
        snap.priorChatMarkdown = priorChatMarkdown
        return snap
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-retentionSeconds)
        while let first = lines.first, first.at < cutoff {
            lines.removeFirst()
        }
    }
}

/// Tiny LRU-ish set that preserves insertion order and dedupes case-insensitively.
private struct OrderedSet<T: Hashable> {
    private(set) var values: [T] = []
    private var seen: Set<T> = []
    let maxSize: Int

    init(maxSize: Int) { self.maxSize = maxSize }

    mutating func insert(_ value: T) {
        if seen.contains(value) { return }
        seen.insert(value)
        values.append(value)
        if values.count > maxSize, let dropped = values.first {
            values.removeFirst()
            seen.remove(dropped)
        }
    }

    mutating func clear() {
        values.removeAll()
        seen.removeAll()
    }
}
