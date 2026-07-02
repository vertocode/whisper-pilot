import AVFoundation
import Foundation
import Speech

/// Streaming transcription via the macOS 26 `SpeechAnalyzer` framework. One analyzer +
/// transcriber pair per channel — they run on independent actors with independent input
/// streams, so mic and system audio never share state and can't stall each other.
///
/// Versus the legacy `SFSpeechRecognizer`-based `AppleSpeechTranscriber`:
/// - no ~60 s hard per-task limit, so we don't need the restart-on-error machinery
/// - no "No speech detected" silence-timeout failure mode
/// - no manual VAD-driven `cycleAtBoundary`/`continueAfterFinalization` cycling — the
///   analyzer emits volatile partials that flip to finalized on its own boundary calls
/// - finalization signal is `result.isFinal` on each `SpeechTranscriber.Result`:
///   volatile results replace each other for the current audio range until one
///   finalized (immutable, non-overlapping) result commits it
@available(macOS 26.0, *)
final class SpeechAnalyzerTranscriber: TranscriptionProvider, @unchecked Sendable {
    let transcripts: AsyncStream<TranscriptUpdate>
    private let continuation: AsyncStream<TranscriptUpdate>.Continuation
    private let locale: Locale

    private let mutex = NSLock()
    private var pipes: [AudioChannel: Pipe] = [:]
    private var isStopped = false

    init(locale: Locale) {
        self.locale = locale
        var captured: AsyncStream<TranscriptUpdate>.Continuation!
        self.transcripts = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { c in captured = c }
        self.continuation = captured
    }

    func start(enabledChannels: Set<AudioChannel>) async throws {
        wpInfo("SpeechAnalyzer.start (locale=\(locale.identifier), channels=\(enabledChannels))")
        try await ensureAuthorization()

        // Only build pipes for channels that will actually receive audio. Skipping
        // an unused channel avoids spinning up its SpeechAnalyzer + a download of
        // the locale's model for a pipe that would never see a buffer.
        let wantMic = enabledChannels.contains(.microphone)
        let wantSys = enabledChannels.contains(.system)

        // Build the requested pipes in parallel — asset install + format probe can
        // take a noticeable moment on first launch; doing them concurrently halves
        // startup when both are wanted.
        async let micPipe: Pipe? = wantMic ? Pipe.make(channel: .microphone, locale: locale, sink: continuation) : nil
        async let sysPipe: Pipe? = wantSys ? Pipe.make(channel: .system, locale: locale, sink: continuation) : nil
        let mic = try await micPipe
        let sys = try await sysPipe

        if !installPipes(mic: mic, sys: sys) {
            mic?.finish()
            sys?.finish()
            return
        }
        wpInfo("SpeechAnalyzer: channel pipes ready (mic=\(mic != nil), sys=\(sys != nil))")
    }

    /// Non-async wrapper around the locked dict update — Swift 6 strict concurrency
    /// rejects `NSLock.lock()` from an async function. Returns `false` if `stop()`
    /// raced ahead of us; the caller is then responsible for finishing the pipes.
    private func installPipes(mic: Pipe?, sys: Pipe?) -> Bool {
        mutex.lock()
        defer { mutex.unlock() }
        if isStopped { return false }
        if let mic { pipes[.microphone] = mic }
        if let sys { pipes[.system] = sys }
        return true
    }

    func stop() {
        mutex.lock()
        isStopped = true
        let current = pipes
        pipes.removeAll()
        mutex.unlock()
        for pipe in current.values { pipe.finish() }
        wpInfo("SpeechAnalyzer: stopped")
    }

    func feed(_ buffer: AVAudioPCMBuffer, channel: AudioChannel) {
        mutex.lock()
        let pipe = pipes[channel]
        mutex.unlock()
        pipe?.feed(buffer)
    }

    /// SpeechAnalyzer does its own segmentation, so VAD boundary events are advisory.
    /// We don't force a cycle here — letting the analyzer pick finalization points
    /// produces cleaner, less fragmented lines than legacy SFSpeech did.
    func notifyVADBoundary(channel: AudioChannel) {}

    /// SpeechAnalyzer can hold a result volatile for a long stretch (it only
    /// commits when its volatile range advances), and `context.absorb` plus the
    /// transcript.md persistence path only ingest finals. Without this flush, a
    /// short utterance spoken right before a prompt — a wake-word command in
    /// particular — never lands in the AI context or transcript.md until the
    /// analyzer happens to finalize, which may be teardown-time when nobody is
    /// listening anymore. Mirrors `AppleSpeechTranscriber`'s synthetic-final
    /// flush: emit the current volatile hypothesis as `isFinal=true` through
    /// the normal stream (so every downstream consumer sees it) and return it
    /// for synchronous absorption. A later natural final with the same segment
    /// id harmlessly replaces it everywhere — all consumers key by id.
    func collectPendingFinals() -> [TranscriptUpdate] {
        mutex.lock()
        let current = pipes
        mutex.unlock()
        return current.values.compactMap { $0.takePendingFinal() }
    }

    deinit {
        continuation.finish()
    }

    private func ensureAuthorization() async throws {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized { return }
        if status == .denied || status == .restricted {
            throw TranscriberError.notAuthorized
        }
        let granted: Bool = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        if !granted { throw TranscriberError.notAuthorized }
    }
}

@available(macOS 26.0, *)
private final class Pipe: @unchecked Sendable {
    let channel: AudioChannel
    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let canonicalFormat: AVAudioFormat
    private let analyzerFormat: AVAudioFormat?
    private let converter: AVAudioConverter?
    private let sink: AsyncStream<TranscriptUpdate>.Continuation

    private let mutex = NSLock()
    private var isFinished = false
    /// Segment id for the analyzer's *current* audio range. The WWDC25 contract:
    /// volatile results for a range keep replacing each other until one last
    /// finalized result commits that range, after which the transcriber moves
    /// on to the next range. We mint one id when a range's first result arrives,
    /// reuse it for every volatile refinement, emit the final under it, then
    /// clear it so the next range starts a fresh transcript line. No wall-clock
    /// heuristics — segment identity tracks the analyzer's own range lifecycle.
    private var currentSegmentId: UUID?
    private var buffersFed: Int = 0
    private var resultsSeen: Int = 0
    /// Latest hypothesis for the active segment, plus whether the analyzer has
    /// already committed it. Backs `takePendingFinal` — the pre-prompt flush
    /// that turns a still-volatile utterance into a synthetic final so the AI
    /// context and transcript.md persistence (final-only consumers) ingest it.
    private var pendingText: String = ""
    private var pendingSegmentId: UUID?
    private var pendingHasNaturalFinal = true

    static func make(
        channel: AudioChannel,
        locale: Locale,
        sink: AsyncStream<TranscriptUpdate>.Continuation
    ) async throws -> Pipe {
        guard SpeechTranscriber.isAvailable else {
            wpError("SpeechAnalyzer.\(channel): SpeechTranscriber not available on this system")
            throw TranscriberError.unavailable(locale.identifier)
        }
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            wpError("SpeechAnalyzer.\(channel): locale \(locale.identifier) is not supported")
            throw TranscriberError.unavailable(locale.identifier)
        }

        let transcriber = SpeechTranscriber(locale: resolved, preset: .progressiveTranscription)
        let assetStatus = await AssetInventory.status(forModules: [transcriber])
        wpInfo("SpeechAnalyzer.\(channel): locale=\(resolved.identifier), asset status=\(assetStatus)")
        switch assetStatus {
        case .unsupported:
            throw TranscriberError.unavailable(resolved.identifier)
        case .installed:
            break
        case .supported, .downloading:
            wpInfo("SpeechAnalyzer.\(channel): installing on-device model for \(resolved.identifier)…")
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
                wpInfo("SpeechAnalyzer.\(channel): on-device model installed")
            } else {
                // No request returned even though status was "supported/downloading" —
                // usually means another process is already installing it. Proceed and
                // let analyzer.start() surface a real error if the model truly isn't ready.
                wpWarn("SpeechAnalyzer.\(channel): assetInstallationRequest returned nil — proceeding optimistically")
            }
        @unknown default:
            wpWarn("SpeechAnalyzer.\(channel): unknown asset status \(assetStatus) — proceeding optimistically")
        }

        // Sharing the model across both pipes in this process avoids loading it twice
        // (~hundreds of MB depending on locale). Each analyzer is still its own actor
        // with its own state, just backed by the same retained model.
        let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: options)

        let canonical = CanonicalAudioFormat.make()
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let converter: AVAudioConverter?
        if let target = analyzerFormat, !audioFormatMatches(target, canonical) {
            converter = AVAudioConverter(from: canonical, to: target)
        } else {
            converter = nil
        }
        if let analyzerFormat {
            wpInfo("SpeechAnalyzer.\(channel): analyzer format = \(analyzerFormat.sampleRate) Hz, \(analyzerFormat.channelCount) ch, commonFormat=\(analyzerFormat.commonFormat.rawValue)")
        } else {
            wpWarn("SpeechAnalyzer.\(channel): no bestAvailableAudioFormat — feeding canonical 16 kHz")
        }

        // Warm up the analyzer with the format it'll see. Avoids a multi-second hitch
        // on the first buffer when the model lazy-loads.
        do {
            try await analyzer.prepareToAnalyze(in: analyzerFormat)
        } catch {
            wpWarn("SpeechAnalyzer.\(channel): prepareToAnalyze failed (\(error.localizedDescription)) — proceeding")
        }

        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )

        try await analyzer.start(inputSequence: inputStream)

        let pipe = Pipe(
            channel: channel,
            analyzer: analyzer,
            transcriber: transcriber,
            inputContinuation: inputContinuation,
            canonicalFormat: canonical,
            analyzerFormat: analyzerFormat,
            converter: converter,
            sink: sink
        )
        pipe.startConsumingResults()
        return pipe
    }

    private init(
        channel: AudioChannel,
        analyzer: SpeechAnalyzer,
        transcriber: SpeechTranscriber,
        inputContinuation: AsyncStream<AnalyzerInput>.Continuation,
        canonicalFormat: AVAudioFormat,
        analyzerFormat: AVAudioFormat?,
        converter: AVAudioConverter?,
        sink: AsyncStream<TranscriptUpdate>.Continuation
    ) {
        self.channel = channel
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.inputContinuation = inputContinuation
        self.canonicalFormat = canonicalFormat
        self.analyzerFormat = analyzerFormat
        self.converter = converter
        self.sink = sink
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        mutex.lock()
        if isFinished { mutex.unlock(); return }
        mutex.unlock()

        let converted: AVAudioPCMBuffer
        if let converter {
            // Streaming conversion — no per-buffer reset, so the resampler's
            // filter state carries across buffers. See `StreamingAudioConverter`.
            guard let out = StreamingAudioConverter.convert(buffer, using: converter, label: "SpeechAnalyzer.\(channel)") else { return }
            converted = out
        } else {
            converted = buffer
        }

        mutex.lock()
        buffersFed += 1
        let count = buffersFed
        mutex.unlock()

        if count == 1 || count % 200 == 0 {
            wpInfo("SpeechAnalyzer.\(channel) buffer#\(count) frames=\(converted.frameLength)")
        }

        inputContinuation.yield(AnalyzerInput(buffer: converted))
    }

    func finish() {
        mutex.lock()
        if isFinished { mutex.unlock(); return }
        isFinished = true
        mutex.unlock()

        // Close the input stream so the analyzer sees end-of-input, then let it flush.
        // `cancelAndFinishNow` is the abort path; we want graceful finalization so any
        // tail audio still in flight gets transcribed before we tear down.
        inputContinuation.finish()
        let analyzer = self.analyzer
        Task.detached { [channel] in
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                wpInfo("SpeechAnalyzer.\(channel) finalized cleanly")
            } catch {
                wpWarn("SpeechAnalyzer.\(channel) finalize threw: \(error.localizedDescription)")
                await analyzer.cancelAndFinishNow()
            }
        }
    }

    private func startConsumingResults() {
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                for try await result in self.transcriber.results {
                    self.handleResult(result)
                }
                wpInfo("SpeechAnalyzer.\(self.channel) results stream ended (\(self.resultsSeen) results)")
            } catch {
                wpError("SpeechAnalyzer.\(self.channel) results error: \(error.localizedDescription)")
            }
        }
    }

    private func handleResult(_ result: SpeechTranscriber.Result) {
        // SpeechTranscriber.Result.text is an AttributedString; we only need the plain
        // string for our transcript buffer. Span runs over `.characters` is the
        // documented way to get the underlying UTF-8/grapheme text out without losing
        // characters to the attribute machinery.
        let text = String(result.text.characters)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }

        // `isFinal` comes straight from the transcriber: volatile results keep
        // replacing each other for the current audio range; the one finalized
        // result commits the range and the analyzer moves on. Finalized results
        // are immutable and never overlap (WWDC25 session 277 contract).
        let isFinal = result.isFinal
        mutex.lock()
        let segmentId = currentSegmentId ?? UUID()
        currentSegmentId = isFinal ? nil : segmentId
        resultsSeen += 1
        let count = resultsSeen
        // Track the active hypothesis for the pre-prompt synthetic-final flush.
        // A natural final disarms it; the next volatile result re-arms it.
        pendingText = text
        pendingSegmentId = segmentId
        pendingHasNaturalFinal = isFinal
        mutex.unlock()

        let update = TranscriptUpdate(
            id: segmentId,
            text: text,
            isFinal: isFinal,
            channel: channel,
            timestamp: Date()
        )
        sink.yield(update)

        if count == 1 {
            wpInfo("SpeechAnalyzer.\(channel) FIRST result: \"\(text)\" final=\(isFinal)")
        }
    }

    /// Emit the current still-volatile hypothesis as a synthetic `isFinal=true`
    /// update, both through the normal stream (display, persistence, context
    /// consumers) and as a return value for synchronous pre-prompt absorption.
    /// Idempotent: once flushed, subsequent calls return nil until a new
    /// volatile result re-arms the pending state. Same contract as
    /// `AppleSpeechTranscriber.ChannelPipe.takePendingFinal`.
    fileprivate func takePendingFinal() -> TranscriptUpdate? {
        mutex.lock()
        let needs = !pendingHasNaturalFinal && !pendingText.isEmpty && pendingSegmentId != nil
        let text = pendingText
        let id = pendingSegmentId
        pendingHasNaturalFinal = true
        mutex.unlock()
        guard needs, let id else { return nil }
        let update = TranscriptUpdate(
            id: id,
            text: text,
            isFinal: true,
            channel: channel,
            timestamp: Date()
        )
        sink.yield(update)
        wpInfo("SpeechAnalyzer.\(channel) flushed synthetic FINAL: \"\(text)\"")
        return update
    }
}

/// AVAudioFormat doesn't implement value equality the way we want — `==` compares the
/// CoreAudio AudioStreamBasicDescription including layout tags that don't actually
/// affect sample compatibility. For our "should we install a converter?" check we just
/// care about sample rate, channel count, and common format.
@available(macOS 26.0, *)
private func audioFormatMatches(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
    a.sampleRate == b.sampleRate
        && a.channelCount == b.channelCount
        && a.commonFormat == b.commonFormat
        && a.isInterleaved == b.isInterleaved
}
