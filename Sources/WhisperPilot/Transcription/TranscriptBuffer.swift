import Foundation

struct TranscriptSegment: Sendable, Hashable, Identifiable {
    let id: UUID
    var text: String
    var isFinal: Bool
    var channel: AudioChannel
    var startedAt: Date
    var updatedAt: Date
}

/// Shared containment-merge logic for consecutive finalized transcript lines.
/// The recognizers can legitimately finalize one utterance twice under two
/// different segment ids (a synthetic pre-flush followed by the recognizer's
/// own final, or replay overlap at a task seam). Every consumer of finals —
/// the display buffer, the AI context, and transcript.md persistence — must
/// collapse those pairs the same way, or the on-screen transcript, the
/// model's view, and the saved file drift apart.
enum TranscriptDedup {
    /// How close (by wall clock) two finals must be for containment-based
    /// merging to apply. Outside this window an identical line is far more
    /// likely a genuine repeat ("yeah… [a minute passes] …yeah").
    static let mergeWindowSeconds: TimeInterval = 10

    /// Case- and punctuation-insensitive comparison key, so "Hello, world."
    /// and "hello world" count as the same utterance.
    static func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// If `previous` and `incoming` are containment-duplicates (one's
    /// normalized *word sequence* contains the other's as a contiguous run),
    /// returns the text to keep — whichever is more complete. Returns nil when
    /// they're distinct utterances. Word-level matching, not substring: "we
    /// ship" must NOT merge into "they said we shipped it".
    static func merged(previous: String, incoming: String) -> String? {
        let p = normalized(previous).split(separator: " ")
        let i = normalized(incoming).split(separator: " ")
        guard !p.isEmpty, !i.isEmpty else { return nil }
        // Equal content: keep the newer emission — the recognizer's own final
        // pass carries better punctuation/casing than the synthetic pre-flush.
        if p == i { return incoming }
        if containsContiguousRun(haystack: p, needle: i) { return previous }
        if containsContiguousRun(haystack: i, needle: p) { return incoming }
        return nil
    }

    private static func containsContiguousRun(haystack: [Substring], needle: [Substring]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }
}

/// Live-caption display model, following the pattern production captioners
/// (Google Meet, YouTube, Teams) converge on:
///
/// - **Finalized segments are append-only and immutable.** Once a line is
///   committed it never gets rewritten by a later hypothesis — the only
///   in-place mutation allowed is a repeated final for the *same* segment id
///   (the pre-prompt synthetic-final flush legitimately re-emits a growing
///   final for one utterance).
/// - **At most one volatile (in-progress) segment per channel.** Every
///   volatile update replaces that channel's slot wholesale; the recognizer's
///   whole-hypothesis partials are never accumulated into extra rows. This is
///   what structurally prevents "one phrase shows up as many lines".
/// - **A final on a channel consumes that channel's volatile slot**, whatever
///   ids either carries. Recognizers (both SFSpeech and SpeechAnalyzer) can
///   emit the final under a different id than the partials that preceded it;
///   keying the volatile slot by channel instead of id is what collapses the
///   gray-row/white-row duplicate pair.
/// - **Consecutive finals on a channel are merged when one's normalized text
///   contains the other's** (within a short window). That absorbs the
///   synthetic-final → natural-final double emission and replay-overlap
///   near-duplicates without ever suppressing a genuine repeat said minutes
///   apart.
actor TranscriptBuffer {
    private var finals: [TranscriptSegment] = []
    private var finalIndexByID: [UUID: Int] = [:]
    private var volatileByChannel: [AudioChannel: TranscriptSegment] = [:]

    private static let maxFinals = 150

    func apply(_ update: TranscriptUpdate) {
        let trimmed = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if update.isFinal {
            applyFinal(update, trimmed: trimmed)
        } else {
            applyVolatile(update, trimmed: trimmed)
        }
    }

    private func applyVolatile(_ update: TranscriptUpdate, trimmed: String) {
        // Empty hypotheses never earn a row.
        guard !trimmed.isEmpty else { return }

        // A volatile whose segment was already committed is the same utterance
        // still in progress: the pre-prompt synthetic-final flush commits the
        // hypothesis mid-speech, and the recognizer keeps refining under the
        // same id. Grow the committed line in place (it keeps its white,
        // finalized styling) rather than resurrecting a gray duplicate below it
        // — or worse, dropping the rest of the sentence from the display.
        if let idx = finalIndexByID[update.id] {
            finals[idx].text = update.text
            finals[idx].updatedAt = update.timestamp
            return
        }

        if let existing = volatileByChannel[update.channel] {
            volatileByChannel[update.channel] = TranscriptSegment(
                id: update.id,
                text: update.text,
                isFinal: false,
                channel: update.channel,
                startedAt: existing.startedAt,
                updatedAt: update.timestamp
            )
        } else {
            volatileByChannel[update.channel] = TranscriptSegment(
                id: update.id,
                text: update.text,
                isFinal: false,
                channel: update.channel,
                startedAt: update.timestamp,
                updatedAt: update.timestamp
            )
        }
    }

    private func applyFinal(_ update: TranscriptUpdate, trimmed: String) {
        // Repeated final for an already-committed segment: refresh its text in
        // place (the synthetic-final flush re-emits one utterance as it grows).
        if let idx = finalIndexByID[update.id] {
            if !trimmed.isEmpty {
                finals[idx].text = update.text
            }
            finals[idx].updatedAt = update.timestamp
            if volatileByChannel[update.channel]?.id == update.id {
                volatileByChannel[update.channel] = nil
            }
            return
        }

        // The final supersedes whatever hypothesis was showing on this channel.
        let consumedVolatile = volatileByChannel.removeValue(forKey: update.channel)

        guard !trimmed.isEmpty else {
            // Recognizers emit empty finals on session boundaries. Never let one
            // erase real text: if a hypothesis was on screen, commit it instead.
            if let vol = consumedVolatile,
               !vol.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                appendFinal(TranscriptSegment(
                    id: vol.id,
                    text: vol.text,
                    isFinal: true,
                    channel: vol.channel,
                    startedAt: vol.startedAt,
                    updatedAt: update.timestamp
                ))
            }
            return
        }

        // Containment merge against the previous final on this channel. Catches
        // the synthetic-final → natural-final pair (same utterance, different
        // ids) and replay-overlap near-duplicates at task boundaries.
        if let lastIdx = lastFinalIndex(on: update.channel),
           update.timestamp.timeIntervalSince(finals[lastIdx].updatedAt) <= TranscriptDedup.mergeWindowSeconds,
           let mergedText = TranscriptDedup.merged(previous: finals[lastIdx].text, incoming: update.text) {
            finals[lastIdx].text = mergedText
            finals[lastIdx].updatedAt = update.timestamp
            finalIndexByID[update.id] = lastIdx
            return
        }

        appendFinal(TranscriptSegment(
            id: update.id,
            text: update.text,
            isFinal: true,
            channel: update.channel,
            // Anchor the committed line where its hypothesis started so the row
            // doesn't jump when the volatile flips to final.
            startedAt: consumedVolatile?.startedAt ?? update.timestamp,
            updatedAt: update.timestamp
        ))
    }

    private func appendFinal(_ segment: TranscriptSegment) {
        finals.append(segment)
        finalIndexByID[segment.id] = finals.count - 1
        if finals.count > Self.maxFinals {
            let excess = finals.count - Self.maxFinals
            finals.removeFirst(excess)
            finalIndexByID = Dictionary(
                uniqueKeysWithValues: finals.enumerated().map { ($0.element.id, $0.offset) }
            )
        }
    }

    private func lastFinalIndex(on channel: AudioChannel) -> Int? {
        finals.lastIndex(where: { $0.channel == channel })
    }

    /// Ordered list for UI rendering: committed lines first (chronological),
    /// then the in-progress hypothesis rows (at most one per channel).
    func snapshot() -> [TranscriptSegment] {
        finals + volatileByChannel.values.sorted { $0.startedAt < $1.startedAt }
    }

    func lastFinalized() -> TranscriptSegment? {
        finals.last
    }

    /// Most recent segment on the given channel regardless of finalization
    /// state. The trigger engine uses this to react to a question the moment
    /// the speaker pauses, before the recognizer finalizes.
    func lastSegment(on channel: AudioChannel) -> TranscriptSegment? {
        if let vol = volatileByChannel[channel] { return vol }
        for segment in finals.reversed() where segment.channel == channel {
            return segment
        }
        return nil
    }

    func clear() {
        finals.removeAll()
        finalIndexByID.removeAll()
        volatileByChannel.removeAll()
    }
}
