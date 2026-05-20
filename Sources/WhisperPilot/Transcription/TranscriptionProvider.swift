import AVFoundation
import Foundation

struct TranscriptUpdate: Sendable, Hashable, Identifiable {
    let id: UUID
    let text: String
    let isFinal: Bool
    let channel: AudioChannel
    let timestamp: Date
}

protocol TranscriptionProvider: AnyObject, Sendable {
    var transcripts: AsyncStream<TranscriptUpdate> { get }
    /// Spin up recognizer pipes for the given channels only. Callers should pass
    /// just the channels whose audio will actually be fed in — creating an idle
    /// pipe for an unused channel produces misleading "No speech detected"
    /// log noise from a recognizer that's correctly timing out on empty input.
    func start(enabledChannels: Set<AudioChannel>) async throws
    func stop()
    func feed(_ buffer: AVAudioPCMBuffer, channel: AudioChannel)
    /// Tells the transcriber that an utterance boundary was detected on this channel
    /// (e.g. by VAD on speech end). Implementations should finalize the current segment
    /// so the next partial begins a new transcript line — without this, dictation-mode
    /// recognizers tend to keep overwriting one ever-growing segment.
    func notifyVADBoundary(channel: AudioChannel)
    /// Collect synthetic `isFinal=true` updates for any in-progress partials the
    /// recognizer hasn't naturally finalized yet, yield them via the `transcripts`
    /// stream (so the buffer + transcript.md catch up), and return them so the
    /// coordinator can directly absorb them into the AI context BEFORE building a
    /// prompt. Without this, a user who speaks and immediately asks the AI gets
    /// "I don't know what you said" because partials never reached
    /// `ConversationContext` (which gates on `isFinal=true`). Idempotent: a second
    /// call with no new partial in between returns an empty array.
    func collectPendingFinals() -> [TranscriptUpdate]
}
