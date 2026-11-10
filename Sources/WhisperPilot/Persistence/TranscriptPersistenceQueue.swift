import Foundation

/// Decides which finalized lines go to `transcript.md`, one line per utterance
/// with its most complete text. A line waits here until the next utterance
/// proves it is finished, because the pre-prompt synthetic flush can finalize
/// one utterance several times as it grows.
///
/// Every decision is synchronous on purpose. If the pending line only changed
/// after awaiting the disk write, a second final arriving during that wait
/// would find the old line still pending: that line would be written twice and
/// the one replacing it never.
struct TranscriptPersistenceQueue {
    struct Line: Sendable, Equatable {
        let channel: AudioChannel
        let id: UUID
        let text: String
        let timestamp: Date
    }

    private var pendingByChannel: [AudioChannel: Line] = [:]
    private var lastPersistedByChannel: [AudioChannel: Line] = [:]
    private var drainedIDByChannel: [AudioChannel: UUID] = [:]

    /// Takes in one transcript update. Returns the line that must now be
    /// written, if this update proved the previous one finished.
    mutating func accept(_ update: TranscriptUpdate) -> Line? {
        guard update.isFinal,
              !update.text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let channel = update.channel
        // A late re-final of a line that already went to disk (the next
        // utterance pushed it out before the recognizer's own final landed)
        // can't be merged into the file — drop it instead of appending a
        // duplicate line.
        if update.id == drainedIDByChannel[channel] { return nil }
        if let flushed = lastPersistedByChannel[channel],
           update.id == flushed.id
            || (update.timestamp.timeIntervalSince(flushed.timestamp) <= TranscriptDedup.mergeWindowSeconds
                && TranscriptDedup.merged(previous: flushed.text, incoming: update.text) != nil) {
            return nil
        }
        guard let pending = pendingByChannel[channel] else {
            pendingByChannel[channel] = Self.line(from: update, text: update.text)
            return nil
        }
        if pending.id == update.id {
            // Same utterance grew (or the pre-prompt flush emitted again).
            // Containment-guarded: the pending line may already be a
            // merged/rolled-up composite that a fragment must not clobber.
            let text = TranscriptDedup.merged(previous: pending.text, incoming: update.text) ?? pending.text
            pendingByChannel[channel] = Self.line(from: update, text: text)
            return nil
        }
        // Different id but containment-duplicate text shortly after ⇒ the
        // same utterance finalized twice (synthetic pre-flush + the
        // recognizer's own final). Same rule as `TranscriptBuffer` and
        // `ConversationContext`, so the saved transcript.md matches what the
        // user saw on screen.
        if update.timestamp.timeIntervalSince(pending.timestamp) <= TranscriptDedup.mergeWindowSeconds,
           let mergedText = TranscriptDedup.merged(previous: pending.text, incoming: update.text) {
            pendingByChannel[channel] = Self.line(from: update, text: mergedText)
            return nil
        }
        // Continuation of the same speaker turn (task churn finalized
        // mid-sentence) ⇒ append to the pending line, mirroring the display
        // buffer's roll-up, instead of flushing a fragment row.
        if update.timestamp >= pending.timestamp,
           TranscriptDedup.shouldRollUp(
            previousText: pending.text,
            previousAt: pending.timestamp,
            incomingText: update.text,
            incomingAt: update.timestamp
        ) {
            let text = TranscriptDedup.rolledUp(previousText: pending.text, incomingText: update.text)
            pendingByChannel[channel] = Self.line(from: update, text: text)
            return nil
        }
        // Genuinely new utterance ⇒ the previous one is done.
        lastPersistedByChannel[channel] = pending
        pendingByChannel[channel] = Self.line(from: update, text: update.text)
        return pending
    }

    /// Empties every channel's pending line, oldest first. Only the id is
    /// remembered, so the stream's own copy is dropped but a new transcriber's
    /// next line is never mistaken for a repeat of this one.
    mutating func drain() -> [Line] {
        let drained = pendingByChannel.values.sorted { $0.timestamp < $1.timestamp }
        pendingByChannel.removeAll()
        for line in drained { drainedIDByChannel[line.channel] = line.id }
        return drained
    }

    /// The memory of what was written belongs to one session's file.
    mutating func forgetPersistedLines() {
        lastPersistedByChannel.removeAll()
        drainedIDByChannel.removeAll()
    }

    private static func line(from update: TranscriptUpdate, text: String) -> Line {
        Line(channel: update.channel, id: update.id, text: text, timestamp: update.timestamp)
    }
}
