import Foundation

struct TranscriptSegment: Sendable, Hashable, Identifiable {
    let id: UUID
    var text: String
    var isFinal: Bool
    var channel: AudioChannel
    var startedAt: Date
    var updatedAt: Date
}

/// Rolling buffer keyed by segment ID. Partial hypotheses overwrite their slot until finalized.
/// `snapshot()` returns the current ordered list for UI rendering; `lastFinalized()` is what the
/// trigger engine inspects.
actor TranscriptBuffer {
    private var segments: [UUID: TranscriptSegment] = [:]
    private var order: [UUID] = []
    private let retentionSeconds: TimeInterval = 1800

    func apply(_ update: TranscriptUpdate) {
        if var existing = segments[update.id] {
            existing.text = update.text
            existing.isFinal = update.isFinal
            existing.updatedAt = update.timestamp
            segments[update.id] = existing
        } else {
            let segment = TranscriptSegment(
                id: update.id,
                text: update.text,
                isFinal: update.isFinal,
                channel: update.channel,
                startedAt: update.timestamp,
                updatedAt: update.timestamp
            )
            segments[update.id] = segment
            order.append(update.id)
        }
        prune()
    }

    func snapshot() -> [TranscriptSegment] {
        order.compactMap { segments[$0] }
    }

    func lastFinalized() -> TranscriptSegment? {
        for id in order.reversed() {
            if let s = segments[id], s.isFinal { return s }
        }
        return nil
    }

    func clear() {
        segments.removeAll()
        order.removeAll()
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-retentionSeconds)
        while let first = order.first, let segment = segments[first], segment.updatedAt < cutoff {
            order.removeFirst()
            segments.removeValue(forKey: first)
        }
    }
}
