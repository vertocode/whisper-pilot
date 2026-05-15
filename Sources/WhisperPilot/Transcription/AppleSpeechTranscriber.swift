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

    private var systemPipe: ChannelPipe?
    private var micPipe: ChannelPipe?

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
        if enabledChannels.contains(.system) {
            systemPipe = try ChannelPipe(channel: .system, locale: locale, sink: continuation, log: log, autoRestart: autoRestart)
        }
        if enabledChannels.contains(.microphone) {
            micPipe = try ChannelPipe(channel: .microphone, locale: locale, sink: continuation, log: log, autoRestart: autoRestart)
        }
        print("[WP][Transcriber] channel pipes ready (system=\(systemPipe != nil), mic=\(micPipe != nil))")
    }

    func stop() {
        log.info("Stopping transcriber")
        systemPipe?.finish()
        micPipe?.finish()
        systemPipe = nil
        micPipe = nil
    }

    func feed(_ buffer: AVAudioPCMBuffer, channel: AudioChannel) {
        switch channel {
        case .system: systemPipe?.append(buffer)
        case .microphone: micPipe?.append(buffer)
        }
    }

    func notifyVADBoundary(channel: AudioChannel) {
        switch channel {
        case .system: systemPipe?.cycleAtBoundary()
        case .microphone: micPipe?.cycleAtBoundary()
        }
    }

    deinit {
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
    private static let restartDelay: TimeInterval = 0.5
    private var isFinished: Bool = false
    private let mutex = NSLock()
    /// Rolling tail of recently-appended audio (~`replayMaxSeconds` worth). Replayed into
    /// every new request we install so audio that arrived while the previous task was
    /// finalizing (or dying with an error) is recovered. Without this, SFSpeech finalizing
    /// after a comma-length pause silently drops the next ~0.5–2 s of speech — the user
    /// sees "first phrase captured, middle vanished, third phrase captured" even though
    /// the audio pipeline was delivering buffers the whole time. Accepts some text
    /// duplication near task boundaries as a worthwhile trade vs. lost words.
    private var replayBuffers: [AVAudioPCMBuffer] = []
    private var replaySecondsBuffered: Double = 0
    private static let replayMaxSeconds: Double = 1.2

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
        self.request = SFSpeechAudioBufferRecognitionRequest()
        self.request.shouldReportPartialResults = true
        // Permissive: prefer on-device, but allow server fallback. Setting this to `true`
        // when the locale's on-device model isn't fully ready causes the task to silently
        // produce no output — exactly the symptom we kept hitting. Always-false here means
        // recognition will use on-device when available, and Apple's servers when not.
        self.request.requiresOnDeviceRecognition = false
        self.request.taskHint = .dictation
        wpInfo("Transcriber.\(channel) ready (locale=\(locale.identifier), onDeviceSupported=\(recognizer.supportsOnDeviceRecognition), requiresOnDevice=false, autoRestart=\(autoRestart))")
        startTask()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        // Hold the mutex across the request.append call so a concurrent task-swap
        // (continueAfterFinalization / scheduleRestart) can't slip in between reading
        // `self.request` and appending — otherwise this buffer would land on the dead
        // request the swap just replaced and be silently dropped.
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
        mutex.unlock()

        if count == 1 {
            let rms = computeRMS(buffer)
            wpInfo("Transcriber.\(channel) FIRST buffer (frames=\(buffer.frameLength), rms=\(String(format: "%.5f", rms)))")
        } else if count % 100 == 0 {
            let rms = computeRMS(buffer)
            wpInfo("Transcriber.\(channel) appended=\(count) emitted=\(emitted) rms=\(String(format: "%.5f", rms)) restarts=\(restarts)")
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
        let next = SFSpeechAudioBufferRecognitionRequest()
        next.shouldReportPartialResults = true
        next.requiresOnDeviceRecognition = false
        next.taskHint = .dictation
        for buffer in replayBuffers { next.append(buffer) }
        request = next
        segmentId = UUID()
        task = nil
        mutex.unlock()
        oldRequest.endAudio()
        oldTask?.cancel()
        startTask()
    }

    private func startTask() {
        var firstCallback = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if firstCallback {
                wpInfo("Transcriber.\(channel) recognitionTask first callback (result=\(result != nil), error=\(error != nil))")
                firstCallback = false
            }
            if let result {
                let text = result.bestTranscription.formattedString
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

                // SFSpeech sometimes emits empty-text results — typically partials with
                // empty content during state transitions, or empty isFinal markers on
                // session boundaries. Writing those into the buffer either creates rows
                // with no text or, worse, overwrites the previous segment's real text
                // with "". Drop them at the source. Still rotate `segmentId` on empty
                // finals so the next non-empty result starts a fresh transcript line.
                if trimmed.isEmpty {
                    if result.isFinal {
                        segmentId = UUID()
                        self.continueAfterFinalization()
                        // Don't fall through to error handling — we've already replaced
                        // the request + task. A delayed scheduleRestart from a stale
                        // error on the same callback would clobber the new request and
                        // discard everything appended in the meantime.
                        return
                    }
                    return
                }

                let update = TranscriptUpdate(
                    id: segmentId,
                    text: text,
                    isFinal: result.isFinal,
                    channel: channel,
                    timestamp: Date()
                )
                sink.yield(update)
                transcriptsEmitted += 1
                if transcriptsEmitted == 1 {
                    wpInfo("Transcriber.\(channel) FIRST transcript: \"\(update.text)\" final=\(update.isFinal)")
                }
                if result.isFinal {
                    wpInfo("Transcriber.\(channel) FINAL: \"\(update.text)\"")
                    segmentId = UUID()
                    self.continueAfterFinalization()
                    // See comment above — don't fall through to the error branch.
                    return
                }
            }
            if let error {
                wpError("Transcriber.\(channel) recognition error: \(error.localizedDescription)")
                segmentId = UUID()
                if self.autoRestart {
                    self.scheduleRestart()
                }
            }
        }
        wpInfo("Transcriber.\(channel) recognitionTask started (restart#\(restartCount))")
    }

    /// `SFSpeechRecognitionTask` enters a terminal state after errors like "No speech
    /// detected" — every subsequent `request.append(buffer:)` is silently ignored.
    /// Recovery is to drop the request, build a fresh one, and start a new task.
    ///
    /// Swap in the fresh request synchronously so `append()` calls arriving during the
    /// rate-limit delay land on the new (live) request rather than the dead one — the
    /// recognizer task can be attached later because `SFSpeechAudioBufferRecognitionRequest`
    /// buffers audio added before its task starts. Without this, the rate cap (5s backoff)
    /// silently discarded up to 5 s of speech, exactly the "transcript dies after line 3"
    /// symptom we saw.
    ///
    /// Rate-limited only on *task creation* because the recognizer can fire "No speech
    /// detected" repeatedly during silence. Without a cap we'd burn through SFSpeech's
    /// daily task budget and saturate the main thread with log appends.
    private func scheduleRestart() {
        mutex.lock()
        guard !isFinished else { mutex.unlock(); return }
        let now = Date()
        recentRestartTimestamps = recentRestartTimestamps.filter { now.timeIntervalSince($0) < Self.restartWindow }
        let recentCount = recentRestartTimestamps.count
        recentRestartTimestamps.append(now)
        restartCount += 1

        let next = SFSpeechAudioBufferRecognitionRequest()
        next.shouldReportPartialResults = true
        next.requiresOnDeviceRecognition = false
        next.taskHint = .dictation
        for buffer in replayBuffers { next.append(buffer) }
        let replayedCount = replayBuffers.count
        request = next
        task?.cancel()
        task = nil
        mutex.unlock()

        if replayedCount > 0 {
            wpInfo("Transcriber.\(channel) replayed \(replayedCount) buffer(s) into error-restarted request")
        }

        // Don't permanently give up. SFSpeech's "No speech detected" can fire repeatedly
        // during silence; once audio resumes we should still recognize. Slow down task
        // re-attach when the error rate is high but never close the door.
        let delay: TimeInterval = recentCount >= Self.maxRestartsPerWindow ? 5.0 : Self.restartDelay
        if recentCount >= Self.maxRestartsPerWindow {
            wpInfo("Transcriber.\(self.channel) backing off restart attempts (rate cap hit, retrying in \(Int(delay))s)")
        }

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self?.attachTaskIfNeeded()
        }
    }

    /// Re-attach a recognition task to the current request — but only if nothing else
    /// already did. `cycleAtBoundary` / `continueAfterFinalization` can install their own
    /// task between when `scheduleRestart` set up the new request and when its delayed
    /// closure fires; double-attaching would leak a task and clobber transcripts.
    private func attachTaskIfNeeded() {
        mutex.lock()
        guard !isFinished else { mutex.unlock(); return }
        guard task == nil else { mutex.unlock(); return }
        mutex.unlock()
        startTask()
    }

    /// `SFSpeechRecognitionTask` terminates after it delivers `isFinal=true` — including
    /// final results with empty text (which SFSpeech emits on session/utterance boundaries
    /// when it gives up on detecting speech). After termination, every `request.append`
    /// call is silently dropped, so the recognizer captures one phrase and then goes dead
    /// until an error eventually triggers `scheduleRestart`. Spin up a fresh request +
    /// task immediately so continuous speech stays transcribed without a multi-second gap.
    ///
    /// We also seed the new request with the recent audio tail. SFSpeech's internal
    /// "I'm finalizing" decision happens some time before our callback fires, and any
    /// buffers appended during that window were lost to the dead request. Replaying the
    /// last ~1 s of audio recovers them; the cost is occasional duplicated words near
    /// the boundary, which the user will tolerate far better than missing ones.
    private func continueAfterFinalization() {
        mutex.lock()
        guard !isFinished else { mutex.unlock(); return }
        let next = SFSpeechAudioBufferRecognitionRequest()
        next.shouldReportPartialResults = true
        next.requiresOnDeviceRecognition = false
        next.taskHint = .dictation
        for buffer in replayBuffers { next.append(buffer) }
        let replayedCount = replayBuffers.count
        request = next
        task = nil
        mutex.unlock()
        if replayedCount > 0 {
            wpInfo("Transcriber.\(channel) replayed \(replayedCount) buffer(s) into restarted request")
        }
        startTask()
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
