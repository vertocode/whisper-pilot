import Foundation

/// One decoded sub-word token with absolute audio-time bounds (seconds from the
/// start of the channel's audio). `piece` carries SentencePiece text with the
/// `▁` word-boundary marker already mapped to a leading space.
struct StreamToken: Sendable, Equatable {
    let piece: String
    let startTime: TimeInterval
    let endTime: TimeInterval
}

/// A segment the transcriber should emit as a finalized `TranscriptUpdate`.
struct SegmenterFinal: Sendable, Equatable {
    let segmentId: UUID
    let text: String
}

/// Turns a continuous RNNT token stream into utterance-sized transcript segments.
///
/// The Parakeet Unified streaming engine emits one monotonically growing token
/// stream per channel — it has no notion of utterances. This type owns the
/// cutting rules that turn that stream into the lines a live-caption UI shows:
///
/// - **Gap cut** — a new word starting ≥ `gapSeconds` after the previous word
///   ended closes the current segment; the new word opens the next one. This is
///   the primary utterance boundary (a speaker pause), measured on the decoder's
///   own token timings so it can't misfire from decode backlog.
/// - **Idle cut** — the decoder has processed `idleSeconds` of audio past the
///   last emitted token and produced nothing new: the speaker stopped and nobody
///   else started. Closes the segment so the last utterance doesn't sit volatile
///   until the next person speaks. Measured against the *decoded* frontier, not
///   appended audio — the engine buffers ~2 s of lookahead, and measuring against
///   appended audio would cut mid-sentence whenever decode lags real time.
/// - **Length cut** — a monologue with no qualifying pause: close at the first
///   sentence-final punctuation once the segment exceeds `softMaxCharacters`,
///   or unconditionally at `hardMaxCharacters`.
///
/// Word assembly is stateful across `absorb` calls: a word straddling two decode
/// batches (first half of its tokens in one drain, rest in the next) must not be
/// split into two words. Tokens are grouped on their leading-space boundary; a
/// token without a leading space (including punctuation) extends the open word.
///
/// Not thread-safe — the owner serializes access.
final class TranscriptStreamSegmenter {
    struct Config {
        var gapSeconds: TimeInterval = 1.0
        var idleSeconds: TimeInterval = 1.1
        var softMaxCharacters = 480
        var hardMaxCharacters = 800
    }

    private let config: Config

    private(set) var segmentId = UUID()
    /// Completed words of the open segment, in order, each trimmed.
    private var words: [String] = []
    /// Word currently being assembled (may grow with the next absorb call).
    private var openWord = ""
    private var lastTokenEnd: TimeInterval?
    /// Set when `takePendingFinal` flushed the current text; cleared by new tokens.
    private var flushedPendingFinal = false

    init(config: Config = Config()) {
        self.config = config
    }

    /// Current open-segment text ("" when nothing is pending).
    var currentText: String {
        var parts = words
        let trimmedOpen = openWord.trimmingCharacters(in: .whitespaces)
        if !trimmedOpen.isEmpty { parts.append(trimmedOpen) }
        return parts.joined(separator: " ")
    }

    /// Feed newly decoded tokens. Returns finalized segments (usually empty or one).
    func absorb(_ tokens: [StreamToken]) -> [SegmenterFinal] {
        var finals: [SegmenterFinal] = []
        for token in tokens {
            guard !token.piece.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let startsNewWord = token.piece.hasPrefix(" ") || (openWord.isEmpty && words.isEmpty)

            if startsNewWord {
                // Gap cut happens BETWEEN words: this word starts a new utterance,
                // everything assembled so far (including the open word) closes.
                if let lastEnd = lastTokenEnd,
                   token.startTime - lastEnd >= config.gapSeconds,
                   let final = finalizeOpenSegment(includeOpenWord: true) {
                    finals.append(final)
                }
                commitOpenWord()
            }
            openWord += token.piece
            lastTokenEnd = token.endTime
            flushedPendingFinal = false

            if let final = lengthCutIfNeeded() {
                finals.append(final)
            }
        }
        return finals
    }

    /// Report how far (in seconds of audio) the decoder has processed. Fires the
    /// idle cut when the stream has gone quiet past the last emitted token.
    func tick(decodedThrough: TimeInterval) -> SegmenterFinal? {
        guard let lastEnd = lastTokenEnd,
              decodedThrough - lastEnd >= config.idleSeconds else { return nil }
        return finalizeOpenSegment(includeOpenWord: true)
    }

    /// Synthetic pre-prompt flush: return the open segment as a final WITHOUT
    /// closing it — the decoder may still extend this utterance, and later
    /// emissions under the same id let downstream consumers merge in place.
    /// Idempotent until new tokens arrive.
    func takePendingFinal() -> SegmenterFinal? {
        guard !flushedPendingFinal else { return nil }
        let text = currentText
        guard !text.isEmpty else { return nil }
        flushedPendingFinal = true
        return SegmenterFinal(segmentId: segmentId, text: text)
    }

    /// Stream teardown: close whatever is open.
    func finish() -> SegmenterFinal? {
        finalizeOpenSegment(includeOpenWord: true)
    }

    private func commitOpenWord() {
        let trimmed = openWord.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { words.append(trimmed) }
        openWord = ""
    }

    private func lengthCutIfNeeded() -> SegmenterFinal? {
        let text = currentText
        guard text.count >= config.softMaxCharacters else { return nil }
        let endsSentence = text.last.map { ".!?…".contains($0) } ?? false
        guard endsSentence || text.count >= config.hardMaxCharacters else { return nil }
        return finalizeOpenSegment(includeOpenWord: true)
    }

    private func finalizeOpenSegment(includeOpenWord: Bool) -> SegmenterFinal? {
        if includeOpenWord { commitOpenWord() }
        let text = words.joined(separator: " ")
        words.removeAll()
        let id = segmentId
        segmentId = UUID()
        flushedPendingFinal = false
        // Cleared so the idle tick can't re-fire on the (now empty) segment;
        // the gap-cut path re-seeds it from the incoming token immediately.
        lastTokenEnd = nil
        guard !text.isEmpty else { return nil }
        return SegmenterFinal(segmentId: id, text: text)
    }
}
