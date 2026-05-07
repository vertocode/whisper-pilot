import Foundation

/// Merges system + microphone capture streams into a single ordered stream of `AudioFrame`s.
/// Channels are kept distinct (no summing) so downstream stages can attribute transcripts to
/// the correct speaker.
final class AudioMixer: @unchecked Sendable {
    let output: AsyncStream<AudioFrame>
    private let continuation: AsyncStream<AudioFrame>.Continuation

    init() {
        var capturedContinuation: AsyncStream<AudioFrame>.Continuation!
        self.output = AsyncStream(bufferingPolicy: .bufferingNewest(128)) { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation
    }

    func run(systemFrames: AsyncStream<AudioFrame>, micFrames: AsyncStream<AudioFrame>) async {
        await withTaskGroup(of: Void.self) { group in
            let continuation = self.continuation
            group.addTask {
                for await frame in systemFrames { continuation.yield(frame) }
            }
            group.addTask {
                for await frame in micFrames { continuation.yield(frame) }
            }
        }
    }

    deinit {
        continuation.finish()
    }
}
