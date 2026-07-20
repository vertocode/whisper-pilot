import AVFoundation
import Foundation
import OSLog
import Speech

/// Streaming transcription using Apple's `SFSpeechRecognizer` configured for on-device recognition.
/// Two recognizers run in parallel — one per channel — so segments stay attributed to system vs. mic.
final class AppleSpeechTranscriber: NSObject, TranscriptionProvider, @unchecked Sendable {
    let transcripts: AsyncStream<TranscriptUpdate>
    private let continuation: AsyncStream<TranscriptUpdate>.Continuation
    private let log = Logger(subsystem: "com.whisperpilot.app", category: "AppleSpeech")
    private let locale: Locale
    private let autoRestart: Bool

    /// Guards the pipe references: `feed()` runs on the detached pipeline task
    /// while `stop()` nils them from the main actor.
    private let stateLock = NSLock()
    private var systemPipe: ChannelPipe?
    private var micPipe: ChannelPipe?

    private func pipe(for channel: AudioChannel) -> ChannelPipe? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return channel == .system ? systemPipe : micPipe
    }

    init(locale: Locale, autoRestart: Bool = true) {
        self.locale = locale
        self.autoRestart = autoRestart
        var capturedContinuation: AsyncStream<TranscriptUpdate>.Continuation!
        self.transcripts = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation
        super.init()
    }

    func start(enabledChannels: Set<AudioChannel>) async throws {
        print("[WP][Transcriber] start() begin (locale=\(locale.identifier), autoRestart=\(autoRestart), channels=\(enabledChannels))")
        log.info("Starting transcriber for locale=\(self.locale.identifier, privacy: .public) channels=\(String(describing: enabledChannels), privacy: .public)…")
        try await ensureAuthorization()
        print("[WP][Transcriber] auth ok")
        let newSystemPipe = enabledChannels.contains(.system)
            ? try ChannelPipe(channel: .system, locale: locale, sink: continuation, log: log, autoRestart: autoRestart)
            : nil
        let newMicPipe = enabledChannels.contains(.microphone)
            ? try ChannelPipe(channel: .microphone, locale: locale, sink: continuation, log: log, autoRestart: autoRestart)
            : nil
        stateLock.lock()
        systemPipe = newSystemPipe
        micPipe = newMicPipe
        stateLock.unlock()
        print("[WP][Transcriber] channel pipes ready (system=\(newSystemPipe != nil), mic=\(newMicPipe != nil))")
    }

    func stop() {
        log.info("Stopping transcriber")
        stateLock.lock()
        let sys = systemPipe
        let mic = micPipe
        systemPipe = nil
        micPipe = nil
        stateLock.unlock()
        sys?.finish()
        mic?.finish()
    }

    func feed(_ buffer: AVAudioPCMBuffer, channel: AudioChannel) {
        pipe(for: channel)?.append(buffer)
    }

    func notifyVADBoundary(channel: AudioChannel) {
        switch channel {
        case .system: pipe(for: .system)?.cycleAtBoundary()
        case .microphone: pipe(for: .microphone)?.cycleAtBoundary()
        }
    }

    func collectPendingFinals() -> [TranscriptUpdate] {
        [pipe(for: .system)?.takePendingFinal(), pipe(for: .microphone)?.takePendingFinal()].compactMap { $0 }
    }

    deinit {
        // Dropping the transcriber without an explicit `stop()` must still end
        // the channel pipes — each keeps a live recognizer task alive.
        systemPipe?.finish()
        micPipe?.finish()
        continuation.finish()
    }

    private func ensureAuthorization() async throws {
        let status = SFSpeechRecognizer.authorizationStatus()
        log.info("SFSpeechRecognizer current authorization status: \(status.rawValue, privacy: .public)")
        if status == .authorized { return }
        if status == .denied || status == .restricted {
            log.error("Speech recognition denied/restricted; user must enable in System Settings")
            throw TranscriberError.notAuthorized
        }
        log.info("Requesting speech recognition authorization…")
        let granted: Bool = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        if !granted {
            log.error("User denied speech recognition authorization")
            throw TranscriberError.notAuthorized
        }
    }
}

private final class ChannelPipe {
    private let channel: AudioChannel
    private let recognizer: SFSpeechRecognizer
    private var request: SFSpeechAudioBufferRecognitionRequest
    private var task: SFSpeechRecognitionTask?
    private let sink: AsyncStream<TranscriptUpdate>.Continuation
    private let log: Logger
    private let autoRestart: Bool
    private var segmentId = UUID()
    private var buffersAppended: Int = 0
    private var transcriptsEmitted: Int = 0
    private var restartCount: Int = 0
    /// Sliding window of recent restart timestamps. We cap restarts so a chronically
    /// failing recognizer doesn't lock up the app or spam diagnostics.
    private var recentRestartTimestamps: [Date] = []
    private static let maxRestartsPerWindow = 5
    private static let restartWindow: TimeInterval = 30
    /// RMS threshold above which we consider a buffer to contain speech-level
    /// audio. Used to gate task (re)attachment so a long silence doesn't churn
    /// through "No speech detected" → restart → "No speech detected" cycles.
    /// Empirical floor: room noise on a typical Mac mic sits around 0.001–0.003;
    /// real speech is 0.05–0.20. 0.005 cleanly separates the two.
    private static let speechRmsThreshold: Float = 0.005
    private var isFinished: Bool = false
    private let mutex = NSLock()
    /// Last non-empty partial text seen for the current `segmentId`. SFSpeech
    /// will only emit `isFinal=true` if we call `endAudio()` on its request,
    /// which normally happens only at VAD utterance boundaries. Between
    /// boundaries, without a synthetic final the partials never reach
    /// `ConversationContext.absorb` (which gates on `isFinal`), the AI never
    /// sees what the user said, and `transcript.md` stays empty. We remember
    /// the last partial and re-emit it as `isFinal=true` whenever the segment
    /// ends — VAD boundary, scheduled restart, or transcriber stop.
    private var pendingSegmentLastText: String = ""
    /// Set when SFSpeech itself delivered an `isFinal=true` for the current
    /// segment, so the synthetic-final emitter knows not to double-fire.
    private var pendingSegmentHasNaturalFinal: Bool = false
    /// Rolling tail of recently-appended audio (~`replayMaxSeconds` worth), a
    /// portion of which is replayed into each new request so audio that arrived
    /// while the previous task was finalizing (or dying with an error) is
    /// recovered. Without this, SFSpeech finalizing after a comma-length pause
    /// silently drops the next stretch of speech — "first phrase captured,
    /// middle vanished, third phrase captured". How much is replayed depends on
    /// how the previous task ended (see `replayTailLocked` call sites): the full
    /// budget after an error (that audio was never consumed), only
    /// `postFinalReplaySeconds` after a natural final (that audio WAS consumed;
    /// re-feeding it restarts recognition mid-word and garbles text), and
    /// nothing during a finalization storm.
    private var replayBuffers: [AVAudioPCMBuffer] = []
    private var replaySecondsBuffered: Double = 0
    private static let replayMaxSeconds: Double = 1.2
    /// Normalized tail words of the most recent finalized text on this channel,
    /// and when it was finalized. The replay buffer above deliberately re-feeds
    /// the last ~1.2 s of audio into every fresh request so no words are lost at
    /// task boundaries — the cost is that the new task's hypothesis often begins
    /// with words the previous final already committed. We trim that overlap at
    /// the text level: if a new hypothesis arrives shortly after a final and its
    /// leading words match the final's trailing words (case/punctuation
    /// insensitive), the duplicated prefix is dropped before emission.
    private var lastFinalTailWords: [String] = []
    private var lastFinalAt: Date?
    private static let overlapTrimWindowSeconds: TimeInterval = 4
    /// Replay budget after a *natural finalization*. The finalized task consumed
    /// its audio, so only the short callback gap needs covering — replaying the
    /// full 1.2 s tail re-feeds already-transcribed audio that restarts
    /// MID-WORD, and the recognizer then hallucinates mutated fragments
    /// ("sus-pense" → "Spencer", "net-work" → "Work") that no text-level dedup
    /// can catch. Error restarts keep the full budget: their task died without
    /// consuming the tail.
    private static let postFinalReplaySeconds: Double = 0.4
    /// Finalization-storm brake. When SFSpeech gets into a rapid
    /// finalize→restart→replay loop (observed: 3–5 finals/second shredding one
    /// sentence into ~20 garbled fragments), every replay feeds the next
    /// garbage hypothesis. Once `stormFinalThreshold` finals land within
    /// `stormWindowSeconds`, stop replaying entirely until the rate drops —
    /// losing ≤0.4 s of audio beats amplifying the loop.
    private var recentFinalTimestamps: [Date] = []
    private static let stormWindowSeconds: TimeInterval = 3
    private static let stormFinalThreshold = 4

    init(channel: AudioChannel, locale: Locale, sink: AsyncStream<TranscriptUpdate>.Continuation, log: Logger, autoRestart: Bool = true) throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            wpError("Transcriber.\(channel): no SFSpeechRecognizer for locale \(locale.identifier)")
            throw TranscriberError.unavailable(locale.identifier)
        }
        guard recognizer.isAvailable else {
            wpError("Transcriber.\(channel): SFSpeechRecognizer not currently available for \(locale.identifier)")
            throw TranscriberError.unavailable(locale.identifier)
        }
        self.channel = channel
        self.recognizer = recognizer
        self.sink = sink
        self.log = log
        self.autoRestart = autoRestart
        self.request = Self.makeRequest()
        wpInfo("Transcriber.\(channel) ready (locale=\(locale.identifier), onDeviceSupported=\(recognizer.supportsOnDeviceRecognition), requiresOnDevice=false, autoRestart=\(autoRestart))")
        startTask()
    }

    /// One canonical request configuration for every task this pipe creates
    /// (initial, VAD cycle, error restart, post-finalization continuation).
    private static func makeRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Permissive: prefer on-device, but allow server fallback. Setting this to `true`
        // when the locale's on-device model isn't fully ready causes the task to silently
        // produce no output — exactly the symptom we kept hitting. Always-false here means
        // recognition will use on-device when available, and Apple's servers when not.
        request.requiresOnDeviceRecognition = false
        request.taskHint = .dictation
        // Punctuated finals read dramatically better and give the transcript
        // roll-up rule a "sentence is complete" signal to key on.
        request.addsPunctuation = true
        return request
    }

    /// The tail of recently-appended audio to seed into a fresh request, capped
    /// at `maxSeconds` and suppressed entirely during a finalization storm.
    /// Caller must hold `mutex`.
    private func replayTailLocked(maxSeconds: Double) -> [AVAudioPCMBuffer] {
        guard !isInFinalStormLocked() else { return [] }
        var tail: [AVAudioPCMBuffer] = []
        var seconds = 0.0
        for buffer in replayBuffers.reversed() {
            let bufferSeconds = buffer.format.sampleRate > 0
                ? Double(buffer.frameLength) / buffer.format.sampleRate
                : 0
            if seconds + bufferSeconds > maxSeconds { break }
            tail.append(buffer)
            seconds += bufferSeconds
        }
        return tail.reversed()
    }

    /// True while finals are landing faster than any human speaks in distinct
    /// utterances — the finalize→restart feedback loop. Caller must hold `mutex`.
    private func isInFinalStormLocked() -> Bool {
        let now = Date()
        recentFinalTimestamps = recentFinalTimestamps.filter { now.timeIntervalSince($0) < Self.stormWindowSeconds }
        return recentFinalTimestamps.count >= Self.stormFinalThreshold
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        // Hold the mutex across the request.append call so a concurrent task-swap
        // (continueAfterFinalization / scheduleRestart) can't slip in between reading
        // `self.request` and appending — otherwise this buffer would land on the dead
        // request the swap just replaced and be silently dropped.
        let rms = computeRMS(buffer)
        mutex.lock()
        guard !isFinished else { mutex.unlock(); return }
        request.append(buffer)
        let seconds = buffer.format.sampleRate > 0
            ? Double(buffer.frameLength) / buffer.format.sampleRate
            : 0
        replayBuffers.append(buffer)
        replaySecondsBuffered += seconds
        while replaySecondsBuffered > Self.replayMaxSeconds, let first = replayBuffers.first {
            let firstSeconds = first.format.sampleRate > 0
                ? Double(first.frameLength) / first.format.sampleRate
                : 0
            replayBuffers.removeFirst()
            replaySecondsBuffered -= firstSeconds
        }
        buffersAppended += 1
        let count = buffersAppended
        let emitted = transcriptsEmitted
        let restarts = restartCount
        // If we currently have no recognition task and this buffer carries
        // speech-level audio, lazily attach one. This is the recovery path
        // after `scheduleRestart` deliberately leaves the task slot empty
        // during silence — without it, a long silence would keep firing
        // "No speech detected" → restart → silence-timeout loops that hit
        // the rate cap and ate audio during the 5 s backoff window.
        let needsTaskAttach = task == nil && rms >= Self.speechRmsThreshold
        mutex.unlock()

        if count == 1 {
            wpInfo("Transcriber.\(channel) FIRST buffer (frames=\(buffer.frameLength), rms=\(String(format: "%.5f", rms)))")
        } else if count % 100 == 0 {
            wpInfo("Transcriber.\(channel) appended=\(count) emitted=\(emitted) rms=\(String(format: "%.5f", rms)) restarts=\(restarts)")
        }

        if needsTaskAttach {
            startTask()
        }
    }

    private func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        let pointer = channelData.pointee
        var sum: Float = 0
        for i in 0..<frames { sum += pointer[i] * pointer[i] }
        return (sum / Float(frames)).squareRoot()
    }

    func finish() {
        // Flush a synthetic final for the in-flight utterance *before* marking
        // `isFinished` — otherwise the helper short-circuits on the isFinished
        // guard and we leak the last partial. This ensures the last words the
        // user spoke before clicking Stop make it into transcript.md / context.
        emitSyntheticFinalIfPendingAndAdvanceSegment()
        mutex.lock()
        isFinished = true
        let oldRequest = request
        let oldTask = task
        task = nil
        replayBuffers.removeAll()
        replaySecondsBuffered = 0
        mutex.unlock()
        oldRequest.endAudio()
        oldTask?.cancel()
        log.info("[\(String(describing: self.channel), privacy: .public)] ChannelPipe finished. Appended=\(self.buffersAppended), emitted=\(self.transcriptsEmitted), restarts=\(self.restartCount)")
    }

    /// Called by the coordinator on VAD speech-end events. Finalizes the current segment
    /// (its text persists in the transcript buffer) and starts a fresh request + task
    /// with a new segment id — so the next utterance becomes its own transcript line.
    /// Without this, dictation-mode SFSpeech keeps overwriting one segment with the
    /// running cumulative text, which is what the user was seeing.
    func cycleAtBoundary() {
        mutex.lock()
        guard !isFinished else { mutex.unlock(); return }
        // Skip if no audio has been appended yet — nothing to cycle.
        guard buffersAppended > 0 else { mutex.unlock(); return }
        let oldRequest = request
        let oldTask = task
        let next = Self.makeRequest()
        // A VAD boundary means ≥1 s of silence already elapsed — the short tail
        // is silence, and anything older was consumed by the finalized task.
        for buffer in replayTailLocked(maxSeconds: Self.postFinalReplaySeconds) { next.append(buffer) }
        request = next
        task = nil
        mutex.unlock()
        // Race window: SFSpeech *might* deliver isFinal=true between endAudio()
        // and cancel(). To avoid losing this utterance from context / transcript.md
        // when it doesn't, flush a synthetic final now (which also advances
        // segmentId). If the natural final does arrive later it'll be ignored by
        // downstream consumers because `pendingSegmentHasNaturalFinal` was reset.
        emitSyntheticFinalIfPendingAndAdvanceSegment()
        oldRequest.endAudio()
        oldTask?.cancel()
        startTask()
    }

    /// Emit a synthetic `isFinal=true` for the current segment without
    /// advancing it. Used by the coordinator's pre-prompt flush so the AI sees
    /// what the user just spoke, even when the recognizer hasn't naturally
    /// finalized yet. Returns the emitted update so the caller can also
    /// absorb it into `ConversationContext` synchronously (the async stream
    /// path is too late for a freshly-built prompt). Idempotent — once a flush
    /// has fired, the next call returns `nil` until the next partial arrives
    /// and re-arms the flag.
    fileprivate func takePendingFinal() -> TranscriptUpdate? {
        mutex.lock()
        let needs = !pendingSegmentHasNaturalFinal && !pendingSegmentLastText.isEmpty
        let text = pendingSegmentLastText
        let id = segmentId
        let ch = channel
        // Mark the segment as finalized so subsequent flushes / cycle calls
        // don't double-emit. A later natural-final from SFSpeech (or a new
        // partial) will reset this flag and re-arm flushing.
        pendingSegmentHasNaturalFinal = true
        if needs { recordFinalizedTextLocked(text) }
        mutex.unlock()
        guard needs else { return nil }
        let update = TranscriptUpdate(
            id: id,
            text: text,
            isFinal: true,
            channel: ch,
            timestamp: Date()
        )
        sink.yield(update)
        wpInfo("Transcriber.\(ch) flushed synthetic FINAL: \"\(text)\"")
        return update
    }

    /// If we have a non-empty partial that SFSpeech never finalized for us,
    /// emit it now as `isFinal=true` so downstream consumers (context.absorb,
    /// transcript.md persistence) actually ingest the line. Always advances
    /// `segmentId` so the next utterance starts fresh. No-op if the current
    /// segment already received a natural `isFinal=true` or has no text.
    private func emitSyntheticFinalIfPendingAndAdvanceSegment() {
        mutex.lock()
        let needs = !pendingSegmentHasNaturalFinal && !pendingSegmentLastText.isEmpty
        let text = pendingSegmentLastText
        let id = segmentId
        let ch = channel
        pendingSegmentLastText = ""
        pendingSegmentHasNaturalFinal = false
        segmentId = UUID()
        if needs { recordFinalizedTextLocked(text) }
        mutex.unlock()
        if needs {
            sink.yield(TranscriptUpdate(
                id: id,
                text: text,
                isFinal: true,
                channel: ch,
                timestamp: Date()
            ))
            wpInfo("Transcriber.\(ch) synthetic FINAL: \"\(text)\"")
        }
    }

    /// Records the tail of a just-finalized text so the next hypothesis (which
    /// starts from replayed audio) can have its duplicated prefix trimmed.
    /// Caller must hold `mutex`.
    private func recordFinalizedTextLocked(_ text: String) {
        lastFinalTailWords = ReplayOverlapTrimmer.tailWords(of: text)
        let now = Date()
        lastFinalAt = now
        recentFinalTimestamps = recentFinalTimestamps.filter { now.timeIntervalSince($0) < Self.stormWindowSeconds }
        recentFinalTimestamps.append(now)
    }

    /// Drops the leading words of `text` that duplicate the trailing words of
    /// the previous final on this channel. Only applies within
    /// `overlapTrimWindowSeconds` of that final — beyond it, matching words are
    /// far more likely a genuine repetition than replay overlap. Returns the
    /// (possibly empty) remainder.
    private func trimReplayOverlap(_ text: String) -> String {
        mutex.lock()
        let tail = lastFinalTailWords
        let finalAt = lastFinalAt
        mutex.unlock()
        guard let finalAt,
              Date().timeIntervalSince(finalAt) <= Self.overlapTrimWindowSeconds,
              !tail.isEmpty else { return text }
        return ReplayOverlapTrimmer.trim(text, againstTail: tail)
    }

    private func startTask() {
        // Reserve the task slot under the mutex so concurrent callers (append
        // from the audio thread + cycleAtBoundary from main, etc.) can't both
        // race in and create duplicate tasks.
        mutex.lock()
        guard !isFinished else { mutex.unlock(); return }
        guard task == nil else { mutex.unlock(); return }
        let currentRequest = request
        // The segment this task transcribes into. `segmentId` only advances at
        // points that also replace the request + task (natural final, VAD cycle,
        // restart, empty final), so one task maps to exactly one segment — and a
        // *late* callback from a replaced task must attribute its text to the
        // segment the task was created for, never to whatever the shared
        // `segmentId` has moved on to.
        let taskSegmentId = segmentId
        mutex.unlock()

        var firstCallback = true
        let newTask = recognizer.recognitionTask(with: currentRequest) { [weak self] result, error in
            guard let self else { return }
            if firstCallback {
                wpInfo("Transcriber.\(channel) recognitionTask first callback (result=\(result != nil), error=\(error != nil))")
                firstCallback = false
            }
            // True while this callback belongs to the task on the *current*
            // request. `cycleAtBoundary` / `scheduleRestart` swap the request and
            // start a fresh task, but the old task can still deliver late results
            // afterwards (endAudio commonly produces one last isFinal). A stale
            // callback must never mutate the shared segment/pending state or run
            // the task-lifecycle actions (continueAfterFinalization /
            // scheduleRestart) — those belong to the *new* task now. Its final
            // text is still valuable (SFSpeech's closing pass adds punctuation
            // and fixes words), so we emit it under `taskSegmentId`, where all
            // id-keyed consumers merge it into the already-flushed synthetic
            // final in place.
            let isCurrent: () -> Bool = { [weak self] in
                guard let self else { return false }
                self.mutex.lock()
                defer { self.mutex.unlock() }
                return self.request === currentRequest
            }
            if let result {
                let rawText = result.bestTranscription.formattedString
                let rawTrimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

                // SFSpeech sometimes emits empty-text results — typically partials with
                // empty content during state transitions, or empty isFinal markers on
                // session boundaries. Writing those into the buffer either creates rows
                // with no text or, worse, overwrites the previous segment's real text
                // with "". Drop them at the source. Still rotate `segmentId` on empty
                // finals so the next non-empty result starts a fresh transcript line.
                if rawTrimmed.isEmpty {
                    if result.isFinal, isCurrent() {
                        self.emitSyntheticFinalIfPendingAndAdvanceSegment()
                        self.continueAfterFinalization()
                        // Don't fall through to error handling — we've already replaced
                        // the request + task. A delayed scheduleRestart from a stale
                        // error on the same callback would clobber the new request and
                        // discard everything appended in the meantime.
                    }
                    return
                }

                // Strip words duplicated by the replay buffer at the previous task
                // boundary. If the whole hypothesis is overlap (the new task has
                // only re-heard replayed audio so far), skip the emission entirely —
                // otherwise we'd commit a line that duplicates the previous final.
                let text = self.trimReplayOverlap(rawTrimmed)
                if text.isEmpty {
                    if result.isFinal, isCurrent() { self.continueAfterFinalization() }
                    return
                }

                if result.isFinal {
                    // Check-and-mutate under one lock acquisition so a concurrent
                    // cycle/restart can't swap the request between the staleness
                    // check and the state reset.
                    self.mutex.lock()
                    let current = self.request === currentRequest
                    if current {
                        self.segmentId = UUID()
                        self.pendingSegmentLastText = ""
                        self.pendingSegmentHasNaturalFinal = false
                        // Only a current final may update the shared overlap-trim
                        // tail. A stale final's tail was already recorded by the
                        // synthetic flush that replaced its task; re-recording it
                        // here would move `lastFinalAt` forward and could trim
                        // words off the utterance the *new* task is transcribing.
                        self.recordFinalizedTextLocked(text)
                    }
                    self.mutex.unlock()

                    let update = TranscriptUpdate(
                        id: taskSegmentId,
                        text: text,
                        isFinal: true,
                        channel: channel,
                        timestamp: Date()
                    )
                    sink.yield(update)
                    self.mutex.lock()
                    self.transcriptsEmitted += 1
                    self.mutex.unlock()
                    wpInfo("Transcriber.\(channel) FINAL\(current ? "" : " (late)"): \"\(text)\"")
                    if current { self.continueAfterFinalization() }
                    // Don't fall through to the error branch — see comment above.
                    return
                }

                // Partial. A stale task's partial describes audio the synthetic
                // final at swap time already covered — emitting it would fight
                // the new task's hypothesis for the display. Drop it.
                self.mutex.lock()
                let current = self.request === currentRequest
                if current {
                    // Remember the latest partial so we can synthesize an
                    // isFinal=true from it if SFSpeech never delivers one
                    // (endAudio only happens at VAD boundaries, so mid-utterance
                    // the only natural finals come from silence timeouts that we
                    // explicitly catch as errors). Also clear `hasNaturalFinal`
                    // so the next flush (synthetic or natural) re-emits — the new
                    // partial means the previous final no longer reflects what's
                    // being said.
                    self.pendingSegmentLastText = text
                    self.pendingSegmentHasNaturalFinal = false
                }
                self.mutex.unlock()
                guard current else { return }

                let update = TranscriptUpdate(
                    id: taskSegmentId,
                    text: text,
                    isFinal: false,
                    channel: channel,
                    timestamp: Date()
                )
                sink.yield(update)
                self.mutex.lock()
                self.transcriptsEmitted += 1
                let isFirstTranscript = self.transcriptsEmitted == 1
                self.mutex.unlock()
                if isFirstTranscript {
                    wpInfo("Transcriber.\(channel) FIRST transcript: \"\(update.text)\" final=\(update.isFinal)")
                }
            }
            if let error {
                // "No speech detected" (SFSpeech error 1110) is benign — it fires after
                // the recognizer's internal silence timeout and only means we sat in
                // silence too long. Log at info, not error, so it doesn't spam the
                // user's alert badge during a quiet conversation.
                let nserror = error as NSError
                // Code 216 is "recognition request was canceled" — the deliberate
                // outcome of cycleAtBoundary / scheduleRestart / stop cancelling the
                // old task, which have already flushed pending text and installed a
                // replacement. Reacting to it (synthetic flush + restart) would
                // fire against the *new* segment's state.
                if nserror.domain == "kAFAssistantErrorDomain" && nserror.code == 216 {
                    return
                }
                let isNoSpeech = nserror.domain == "kAFAssistantErrorDomain" && nserror.code == 1110
                if isNoSpeech {
                    wpInfo("Transcriber.\(channel) silence timeout (no speech in window) — task will reattach when speech resumes")
                } else {
                    wpError("Transcriber.\(channel) recognition error: \(error.localizedDescription)")
                }
                // The segment is dead. Flush a synthetic final from the last
                // non-empty partial so downstream consumers (ConversationContext,
                // transcript.md persistence) see *something* for this utterance —
                // without it the user speaks, sees the live transcript, and then
                // the AI claims to not know what was said because no isFinal=true
                // ever reached the context. Stale errors (from a task that a
                // cycle/restart already replaced) get neither the flush nor the
                // restart: the swap that replaced them flushed already, and
                // touching the shared state now would corrupt the new segment.
                guard isCurrent() else { return }
                self.emitSyntheticFinalIfPendingAndAdvanceSegment()
                if self.autoRestart {
                    self.scheduleRestart()
                }
            }
        }
        // Commit the new task into the slot we reserved at the top. If we lost
        // the race (another caller installed a task while we were creating
        // ours, or stop() raced ahead), throw this one away.
        mutex.lock()
        if isFinished || task != nil {
            mutex.unlock()
            newTask.cancel()
            return
        }
        task = newTask
        let currentRestart = restartCount
        mutex.unlock()
        wpInfo("Transcriber.\(channel) recognitionTask started (restart#\(currentRestart))")
    }

    /// `SFSpeechRecognitionTask` enters a terminal state after errors like "No speech
    /// detected" — every subsequent `request.append(buffer:)` is silently ignored.
    /// Recovery is to drop the request, build a fresh one, and leave the task slot
    /// empty for `append()` to fill in once it sees non-silent audio.
    ///
    /// The previous version of this method scheduled a delayed `startTask()` via a
    /// `Task.sleep` timer. That looked safe but produced a noisy failure mode in
    /// long silences: the new task fired the same "No speech detected" timeout
    /// 30–60 s later, triggering another restart, which itself timed out, and so
    /// on. After 5 such restarts the rate cap kicked in and audio captured during
    /// the 5-second backoff went unrecognized — exactly the "transcription cuts a
    /// lot" symptom reported on Mac mini installs running the legacy
    /// `SFSpeechRecognizer` path.
    ///
    /// Lazy attach via `append()` (gated on `speechRmsThreshold`) eliminates that
    /// loop: during silence we sit with `task == nil` and burn no recognizer
    /// quota; the moment a buffer arrives with speech-level RMS, `append()` calls
    /// `startTask()` and resumes recognition. The replay buffer guarantees the
    /// first ~1.2 s of speech is fed in along with the request.
    private func scheduleRestart() {
        mutex.lock()
        guard !isFinished else { mutex.unlock(); return }
        let now = Date()
        recentRestartTimestamps = recentRestartTimestamps.filter { now.timeIntervalSince($0) < Self.restartWindow }
        let recentCount = recentRestartTimestamps.count
        recentRestartTimestamps.append(now)
        restartCount += 1

        let next = Self.makeRequest()
        // Error restarts get the full replay budget: the dead task never
        // consumed this audio, so replaying it is recovery, not duplication.
        // (Still suppressed during a finalization storm.)
        let replayTail = replayTailLocked(maxSeconds: Self.replayMaxSeconds)
        for buffer in replayTail { next.append(buffer) }
        let replayedCount = replayTail.count
        request = next
        task?.cancel()
        task = nil
        mutex.unlock()

        if replayedCount > 0 {
            wpInfo("Transcriber.\(channel) replayed \(replayedCount) buffer(s) into restart-fresh request (awaiting speech)")
        }

        if recentCount >= Self.maxRestartsPerWindow {
            // Surfaced only as info now — with the lazy-attach model, the rate
            // cap is more of an indicator that something else is wrong (mic
            // model misconfig, very noisy env producing spurious timeouts)
            // rather than a problem actively losing audio.
            wpInfo("Transcriber.\(self.channel) restart rate cap reached (\(recentCount) in \(Int(Self.restartWindow))s) — still waiting for the next non-silent buffer to attach a task")
        }
    }

    /// `SFSpeechRecognitionTask` terminates after it delivers `isFinal=true` — including
    /// final results with empty text (which SFSpeech emits on session/utterance boundaries
    /// when it gives up on detecting speech). After termination, every `request.append`
    /// call is silently dropped, so the recognizer captures one phrase and then goes dead
    /// until an error eventually triggers `scheduleRestart`. Spin up a fresh request +
    /// task immediately so continuous speech stays transcribed without a multi-second gap.
    ///
    /// We also seed the new request with a SHORT audio tail
    /// (`postFinalReplaySeconds`): SFSpeech's internal "I'm finalizing" decision
    /// happens shortly before our callback fires, and buffers appended in that
    /// gap were lost to the dead request. Only that gap is worth replaying —
    /// the finalized task already consumed everything older, and re-feeding it
    /// restarts recognition mid-word, which is what shredded fast speech into
    /// garbled fragment lines ("Spencer" / "Fence isn't just…").
    private func continueAfterFinalization() {
        mutex.lock()
        guard !isFinished else { mutex.unlock(); return }
        let next = Self.makeRequest()
        let replayTail = replayTailLocked(maxSeconds: Self.postFinalReplaySeconds)
        for buffer in replayTail { next.append(buffer) }
        let replayedCount = replayTail.count
        request = next
        task = nil
        mutex.unlock()
        if replayedCount > 0 {
            wpInfo("Transcriber.\(channel) replayed \(replayedCount) buffer(s) into restarted request")
        }
        startTask()
    }

}

/// Pure word-overlap trimming used by `AppleSpeechTranscriber` at task seams.
/// The replay buffer re-feeds the last ~1.2 s of audio into every fresh
/// recognition request so no words are lost at a task boundary; the cost is
/// that the new task's hypothesis usually begins with words the previous final
/// already committed. This trims that duplicated prefix at the text level.
/// Extracted as a standalone enum so the smoke-test suite can pin its behavior.
enum ReplayOverlapTrimmer {
    /// Longest overlap we look for. ~1.2 s of speech is at most ~5–6 words; 8
    /// gives margin without risking eating a genuinely repeated long phrase.
    static let maxWords = 8

    /// Case/punctuation-insensitive word key used for overlap matching.
    static func normalizeWord(_ word: Substring) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Normalized tail (up to `maxWords`) of a finalized text, for matching
    /// against the next hypothesis's prefix.
    static func tailWords(of text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace)
            .suffix(maxWords)
            .map(normalizeWord)
            .filter { !$0.isEmpty }
    }

    /// Drops the longest leading run of words in `text` that matches a trailing
    /// run of `tail` (both normalized). Returns the (possibly empty) remainder
    /// with original casing/punctuation preserved.
    static func trim(_ text: String, againstTail tail: [String]) -> String {
        guard !tail.isEmpty else { return text }
        let words = text.split(whereSeparator: \.isWhitespace)
        let normalized = words.map(normalizeWord)
        let maxOverlap = min(tail.count, normalized.count)
        var overlap = 0
        for k in stride(from: maxOverlap, through: 1, by: -1) where Array(tail.suffix(k)) == Array(normalized.prefix(k)) {
            overlap = k
            break
        }
        guard overlap > 0 else { return text }
        return words.dropFirst(overlap).joined(separator: " ")
    }
}

enum TranscriberError: LocalizedError {
    case notAuthorized
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Speech recognition is not authorized."
        case .unavailable(let id): return "Speech recognition is unavailable for \(id)."
        }
    }
}
