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

    func apply(_ update: TranscriptUpdate) {
        let incomingTrimmed = update.text.trimmingCharacters(in: .whitespacesAndNewlines)

        if var existing = segments[update.id] {
            let existingTrimmed = existing.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Never wipe out an existing transcript with an empty update — defensive
            // backstop in case the upstream filter doesn't catch one. The recognizer
            // can settle on a final empty marker after a real partial; we want to
            // keep the real text.
            if !existingTrimmed.isEmpty && incomingTrimmed.isEmpty {
                if update.isFinal { existing.isFinal = true }
                existing.updatedAt = update.timestamp
                segments[update.id] = existing
            } else {
                existing.text = update.text
                existing.isFinal = update.isFinal
                existing.updatedAt = update.timestamp
                segments[update.id] = existing
            }
        } else {
            // Don't create a new segment for an empty update — that's just an empty
            // row with a speaker label and no content.
            guard !incomingTrimmed.isEmpty else { return }
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
}
