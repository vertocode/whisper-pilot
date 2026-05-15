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
    /// RMS threshold above which we consider a buffer to contain speech-level
    /// audio. Used to gate task (re)attachment so a long silence doesn't churn
    /// through "No speech detected" → restart → "No speech detected" cycles.
    /// Empirical floor: room noise on a typical Mac mic sits around 0.001–0.003;
    /// real speech is 0.05–0.20. 0.005 cleanly separates the two.
    private static let speechRmsThreshold: Float = 0.005
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
        // Reserve the task slot under the mutex so concurrent callers (append
        // from the audio thread + cycleAtBoundary from main, etc.) can't both
        // race in and create duplicate tasks.
        mutex.lock()
        guard !isFinished else { mutex.unlock(); return }
        guard task == nil else { mutex.unlock(); return }
        let currentRequest = request
        mutex.unlock()

        var firstCallback = true
        let newTask = recognizer.recognitionTask(with: currentRequest) { [weak self] result, error in
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
                // "No speech detected" (SFSpeech error 1110) is benign — it fires after
                // the recognizer's internal silence timeout and only means we sat in
                // silence too long. Log at info, not error, so it doesn't spam the
                // user's alert badge during a quiet conversation.
                let nserror = error as NSError
                let isNoSpeech = nserror.domain == "kAFAssistantErrorDomain" && nserror.code == 1110
                if isNoSpeech {
                    wpInfo("Transcriber.\(channel) silence timeout (no speech in window) — task will reattach when speech resumes")
                } else {
                    wpError("Transcriber.\(channel) recognition error: \(error.localizedDescription)")
                }
                segmentId = UUID()
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
