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

            // SpeechAnalyzer sometimes emits the final result for an utterance with
            // a slightly different `CMTime` `range.start` than the volatile results
            // that preceded it — the analyzer refines its speech-boundary detection
            // as it sees more audio. The transcriber's range-keyed segment-id map
            // then mints a fresh UUID, and the user ends up looking at two rows
            // with identical text: a gray (volatile) one and a white (final) one.
            //
            // Catch this here: if a new update lands and a recent volatile segment
            // on the same channel already shows the same trimmed text, treat them
            // as one utterance. The volatile gets upgraded if the new update is
            // final; the new emission is dropped either way. Only volatile
            // existing segments are eligible so that a real repeated utterance
            // ("yeah… yeah") still produces two transcript rows.
            if let dupId = recentVolatileDuplicate(
                text: incomingTrimmed,
                channel: update.channel,
                near: update.timestamp
            ) {
                mergeDuplicate(into: dupId, with: update)
                return
            }

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

    /// Finds an existing *volatile* segment on the same channel whose trimmed
    /// text exactly matches `text` and whose latest update is within
    /// `duplicateWindowSeconds` of `timestamp`. Returns the segment id or nil.
    /// We scan only the tail of `order` because older segments aren't candidates
    /// for the volatile→final transition we're trying to collapse.
    private func recentVolatileDuplicate(
        text: String,
        channel: AudioChannel,
        near timestamp: Date
    ) -> UUID? {
        for id in order.suffix(8) {
            guard let seg = segments[id], seg.channel == channel else { continue }
            // Skip already-finalized segments. A finalized line with matching text
            // is more likely a genuine repeat than a duplicate emission, so we
            // preserve it as its own row.
            guard !seg.isFinal else { continue }
            let segTrimmed = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if segTrimmed == text,
               timestamp.timeIntervalSince(seg.updatedAt) <= Self.duplicateWindowSeconds {
                return id
            }
        }
        return nil
    }

    /// Collapses the incoming update onto the existing volatile segment we
    /// matched in `recentVolatileDuplicate`. If the incoming is final, promote
    /// the existing to final so the gray row turns white. If the incoming is
    /// also volatile, just refresh the timestamp — the existing already has
    /// the same text, and we don't want a second gray row.
    private func mergeDuplicate(into existingId: UUID, with update: TranscriptUpdate) {
        guard var existing = segments[existingId] else { return }
        if update.isFinal { existing.isFinal = true }
        existing.updatedAt = update.timestamp
        segments[existingId] = existing
    }

    private static let duplicateWindowSeconds: TimeInterval = 6

    func snapshot() -> [TranscriptSegment] {
        order.compactMap { segments[$0] }
    }

    func lastFinalized() -> TranscriptSegment? {
        for id in order.reversed() {
            if let s = segments[id], s.isFinal { return s }
        }
        return nil
    }

    /// Most recent segment on the given channel regardless of finalization state.
    /// Used by the trigger engine so we can react to a question the *moment* the
    /// speaker pauses, instead of waiting for SFSpeech to finalize — which with
    /// `utteranceBoundary = .auto` can take 30+ seconds.
    func lastSegment(on channel: AudioChannel) -> TranscriptSegment? {
        for id in order.reversed() {
            if let s = segments[id], s.channel == channel { return s }
        }
        return nil
    }

    func clear() {
        segments.removeAll()
        order.removeAll()
    }
}
