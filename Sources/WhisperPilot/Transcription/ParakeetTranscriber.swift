import AVFoundation
import FluidAudio
import Foundation

/// Streaming transcription via FluidAudio's Parakeet Unified 0.6B CoreML engine
/// (FastConformer-RNNT, int8 encoder on the Neural Engine). One
/// `StreamingUnifiedAsrManager` per channel — independent actors with independent
/// rolling buffers, so mic and system audio never share decoder state.
///
/// Versus the Apple engines (`SpeechAnalyzerTranscriber` / `AppleSpeechTranscriber`):
/// - Meaningfully lower WER — 1.79% aggregate on LibriSpeech test-clean with
///   punctuation and capitalization, the same accuracy class as the server-side
///   ASR behind Meet/Teams captions. This engine exists purely for transcript
///   quality; the Apple paths remain as fallbacks.
/// - True streaming: ~2 s theoretical latency (1.04 s chunk + 1.04 s right
///   context), stable partials, no task-restart machinery, no silence-timeout
///   failure mode, designed to run for hours.
/// - English-only. The coordinator only selects this engine for English locales.
///
/// The engine emits one continuous token stream per channel with per-token audio
/// timings; `TranscriptStreamSegmenter` turns that stream into utterance-sized
/// segments (pause-based cuts on the decoder's own timings). Models (~600 MB)
/// auto-download from Hugging Face on first use and are cached under
/// Application Support/FluidAudio.
final class ParakeetTranscriber: TranscriptionProvider, @unchecked Sendable {
    let transcripts: AsyncStream<TranscriptUpdate>
    private let continuation: AsyncStream<TranscriptUpdate>.Continuation
    /// User-visible status reporting (model download progress). Called on
    /// arbitrary threads; the coordinator hops to the main actor.
    private let statusNote: @Sendable (String) -> Void

    private let mutex = NSLock()
    private var pipes: [AudioChannel: Pipe] = [:]
    private var isStopped = false

    init(statusNote: @escaping @Sendable (String) -> Void = { _ in }) {
        self.statusNote = statusNote
        var captured: AsyncStream<TranscriptUpdate>.Continuation!
        self.transcripts = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { c in captured = c }
        self.continuation = captured
    }

    func start(enabledChannels: Set<AudioChannel>) async throws {
        wpInfo("Parakeet.start (channels=\(enabledChannels))")

        // Build sequentially: the first manager's load triggers the one-time
        // model download; the second then loads from the same cache instead of
        // racing a duplicate download of the same ~600 MB bundle.
        var built: [AudioChannel: Pipe] = [:]
        for channel in [AudioChannel.system, .microphone] where enabledChannels.contains(channel) {
            built[channel] = try await Pipe.make(
                channel: channel,
                sink: continuation,
                statusNote: statusNote
            )
        }

        mutex.lock()
        let stopped = isStopped
        if !stopped {
            for (channel, pipe) in built { pipes[channel] = pipe }
        }
        mutex.unlock()
        if stopped {
            for pipe in built.values { pipe.finish() }
            return
        }
        wpInfo("Parakeet: channel pipes ready (\(built.keys.map(String.init(describing:)).sorted()))")
    }

    func stop() {
        mutex.lock()
        isStopped = true
        let current = pipes
        pipes.removeAll()
        mutex.unlock()
        for pipe in current.values { pipe.finish() }
        wpInfo("Parakeet: stopped")
    }

    func feed(_ buffer: AVAudioPCMBuffer, channel: AudioChannel) {
        mutex.lock()
        let pipe = pipes[channel]
        mutex.unlock()
        pipe?.feed(buffer)
    }

    /// The segmenter cuts on the decoder's own token timings (pause detection),
    /// which is more reliable than the energy VAD's estimate — its boundary
    /// events are advisory here, same as for `SpeechAnalyzerTranscriber`.
    func notifyVADBoundary(channel: AudioChannel) {}

    func collectPendingFinals() -> [TranscriptUpdate] {
        mutex.lock()
        let current = pipes
        mutex.unlock()
        return current.values.compactMap { $0.takePendingFinal() }
    }

    deinit {
        continuation.finish()
    }
}

/// One channel's engine + pump: an input stream of canonical 16 kHz mono buffers
/// consumed by a single task that feeds the ASR actor, drains decoded token
/// timings into the segmenter, and emits `TranscriptUpdate`s.
private final class Pipe: @unchecked Sendable {
    let channel: AudioChannel
    private let manager: StreamingUnifiedAsrManager
    private let inputContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    private let sink: AsyncStream<TranscriptUpdate>.Continuation

    private let mutex = NSLock()
    private let segmenter = TranscriptStreamSegmenter()
    private var isFinished = false
    /// Seconds of audio appended to the engine so far. The decoded frontier
    /// trails this by the engine's chunk + right-context lookahead.
    private var appendedSeconds: TimeInterval = 0
    private let lookaheadSeconds: TimeInterval
    private var lastVolatileText = ""
    private var consecutiveErrors = 0
    private static let maxConsecutiveErrors = 20

    static func make(
        channel: AudioChannel,
        sink: AsyncStream<TranscriptUpdate>.Continuation,
        statusNote: @escaping @Sendable (String) -> Void
    ) async throws -> Pipe {
        let manager = StreamingUnifiedAsrManager()

        // Progress notes only at coarse milestones — this fires only on the
        // first-ever launch (or after the user clears the cache).
        let milestones = ProgressMilestones()
        try await manager.loadModels(progressHandler: { progress in
            let quarter = Int(progress.fractionCompleted * 4)
            if milestones.shouldAnnounce(quarter) {
                let percent = Int(progress.fractionCompleted * 100)
                statusNote("⬇️ Downloading the high-accuracy speech model (one-time, ~600 MB) — \(percent)%")
            }
        })
        wpInfo("Parakeet.\(channel): models loaded (\(await manager.displayName))")

        let (inputStream, inputContinuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        let engineConfig = await manager.config
        let pipe = Pipe(
            channel: channel,
            manager: manager,
            inputContinuation: inputContinuation,
            sink: sink,
            lookaheadSeconds: Double(engineConfig.chunkSamples + engineConfig.rightSamples) / 16_000.0
        )
        pipe.startPump(input: inputStream)
        return pipe
    }

    private init(
        channel: AudioChannel,
        manager: StreamingUnifiedAsrManager,
        inputContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation,
        sink: AsyncStream<TranscriptUpdate>.Continuation,
        lookaheadSeconds: TimeInterval
    ) {
        self.channel = channel
        self.manager = manager
        self.inputContinuation = inputContinuation
        self.sink = sink
        self.lookaheadSeconds = lookaheadSeconds
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        mutex.lock()
        if isFinished { mutex.unlock(); return }
        mutex.unlock()
        inputContinuation.yield(buffer)
    }

    func finish() {
        mutex.lock()
        if isFinished { mutex.unlock(); return }
        isFinished = true
        mutex.unlock()
        inputContinuation.finish()
    }

    /// Pre-prompt synthetic flush — same contract as the Apple transcribers:
    /// emit the in-progress utterance as `isFinal=true` so final-gated consumers
    /// (AI context, transcript.md) ingest it now; the segmenter keeps the
    /// segment open, and later emissions under the same id merge in place.
    func takePendingFinal() -> TranscriptUpdate? {
        mutex.lock()
        let pending = segmenter.takePendingFinal()
        mutex.unlock()
        guard let pending else { return nil }
        let update = TranscriptUpdate(
            id: pending.segmentId,
            text: pending.text,
            isFinal: true,
            channel: channel,
            timestamp: Date()
        )
        sink.yield(update)
        wpInfo("Parakeet.\(channel) flushed synthetic FINAL: \"\(pending.text)\"")
        return update
    }

    private func startPump(input: AsyncStream<AVAudioPCMBuffer>) {
        Task.detached { [weak self, channel] in
            guard let self else { return }
            var buffersFed = 0
            for await buffer in input {
                buffersFed += 1
                if buffersFed == 1 {
                    wpInfo("Parakeet.\(channel) FIRST buffer (frames=\(buffer.frameLength))")
                }
                do {
                    try await self.manager.appendAudio(buffer)
                    try await self.manager.processBufferedAudio()
                    self.mutex.lock()
                    self.appendedSeconds += buffer.format.sampleRate > 0
                        ? Double(buffer.frameLength) / buffer.format.sampleRate
                        : 0
                    self.consecutiveErrors = 0
                    self.mutex.unlock()
                    let timings = await self.manager.consumeTokenTimings()
                    self.absorbAndEmit(timings)
                } catch {
                    self.mutex.lock()
                    self.consecutiveErrors += 1
                    let failures = self.consecutiveErrors
                    self.mutex.unlock()
                    wpError("Parakeet.\(channel) processing error (#\(failures)): \(error.localizedDescription)")
                    if failures >= Self.maxConsecutiveErrors {
                        wpError("Parakeet.\(channel) too many consecutive errors — stopping this channel")
                        break
                    }
                }
            }

            // Teardown: flush the engine's remaining lookahead audio, then close
            // whatever utterance is still open so the last words the user heard
            // on screen also land in context / transcript.md.
            do {
                _ = try await self.manager.finish()
                let tail = await self.manager.consumeTokenTimings()
                self.absorbAndEmit(tail, decodedEverything: true)
            } catch {
                wpWarn("Parakeet.\(channel) finish threw: \(error.localizedDescription)")
            }
            self.mutex.lock()
            let final = self.segmenter.finish()
            self.mutex.unlock()
            if let final { self.emitFinal(final) }
            await self.manager.cleanup()
            wpInfo("Parakeet.\(channel) pump ended after \(buffersFed) buffers")
        }
    }

    private func absorbAndEmit(_ timings: [TokenTiming], decodedEverything: Bool = false) {
        mutex.lock()
        let tokens = timings.map {
            StreamToken(piece: $0.token, startTime: $0.startTime, endTime: $0.endTime)
        }
        var finals = segmenter.absorb(tokens)
        // Idle cut runs against the decoded frontier: everything appended minus
        // the engine's fixed lookahead (all of it is decoded after finish()).
        let decodedThrough = decodedEverything ? appendedSeconds : appendedSeconds - lookaheadSeconds
        if let idle = segmenter.tick(decodedThrough: decodedThrough) {
            finals.append(idle)
        }
        let volatileText = segmenter.currentText
        let volatileChanged = volatileText != lastVolatileText && !volatileText.isEmpty
        if volatileChanged { lastVolatileText = volatileText }
        if !finals.isEmpty && volatileText.isEmpty { lastVolatileText = "" }
        let volatileId = segmenter.segmentId
        mutex.unlock()

        for final in finals { emitFinal(final) }
        if volatileChanged {
            sink.yield(TranscriptUpdate(
                id: volatileId,
                text: volatileText,
                isFinal: false,
                channel: channel,
                timestamp: Date()
            ))
        }
    }

    private func emitFinal(_ final: SegmenterFinal) {
        sink.yield(TranscriptUpdate(
            id: final.segmentId,
            text: final.text,
            isFinal: true,
            channel: channel,
            timestamp: Date()
        ))
        wpInfo("Parakeet.\(channel) FINAL: \"\(final.text)\"")
    }
}

/// Thread-safe "announce each milestone once" latch for download progress.
private final class ProgressMilestones: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1

    func shouldAnnounce(_ milestone: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard milestone > last else { return false }
        last = milestone
        return true
    }
}
