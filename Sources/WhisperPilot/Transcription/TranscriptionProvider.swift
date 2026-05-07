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
}
