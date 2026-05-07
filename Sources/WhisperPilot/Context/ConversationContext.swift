import Foundation

struct ConversationSnapshot: Sendable {
    let recentLines: [String]
    let topics: [String]
    let entities: [String]
}

/// Rolling memory the LLM sees on every prompt. We keep the recent transcript verbatim and a small
/// set of extracted topics/entities so the model has continuity across turns without us re-sending
/// the whole transcript.
actor ConversationContext {
    private var lines: [(channel: AudioChannel, text: String, at: Date)] = []
    private var topics = OrderedSet<String>(maxSize: 24)
    private var entities = OrderedSet<String>(maxSize: 32)
    private let retentionSeconds: TimeInterval = 300

    private let extractor = TopicExtractor()

    func absorb(_ update: TranscriptUpdate) {
        guard update.isFinal, !update.text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        lines.append((update.channel, update.text, update.timestamp))
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
        let formatted = lines.map { entry -> String in
            let speaker = entry.channel == .system ? "Other" : "Me"
            return "\(speaker): \(entry.text)"
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
