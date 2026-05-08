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
    func start() async throws
    func stop()
    func feed(_ buffer: AVAudioPCMBuffer, channel: AudioChannel)
    /// Tells the transcriber that an utterance boundary was detected on this channel
    /// (e.g. by VAD on speech end). Implementations should finalize the current segment
    /// so the next partial begins a new transcript line — without this, dictation-mode
    /// recognizers tend to keep overwriting one ever-growing segment.
    func notifyVADBoundary(channel: AudioChannel)
}
