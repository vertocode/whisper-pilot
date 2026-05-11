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

    func start() async throws {
        print("[WP][Transcriber] start() begin (locale=\(locale.identifier), autoRestart=\(autoRestart))")
        log.info("Starting transcriber for locale=\(self.locale.identifier, privacy: .public)…")
        try await ensureAuthorization()
        print("[WP][Transcriber] auth ok")
        systemPipe = try ChannelPipe(channel: .system, locale: locale, sink: continuation, log: log, autoRestart: autoRestart)
        micPipe = try ChannelPipe(channel: .microphone, locale: locale, sink: continuation, log: log, autoRestart: autoRestart)
        print("[WP][Transcriber] both channel pipes ready")
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
        mutex.lock()
        let currentRequest = request
        let finished = isFinished
        mutex.unlock()
        guard !finished else { return }
        currentRequest.append(buffer)
        buffersAppended += 1
        if buffersAppended == 1 {
            let rms = computeRMS(buffer)
            wpInfo("Transcriber.\(channel) FIRST buffer (frames=\(buffer.frameLength), rms=\(String(format: "%.5f", rms)))")
        } else if buffersAppended % 100 == 0 {
            let rms = computeRMS(buffer)
            wpInfo("Transcriber.\(channel) appended=\(buffersAppended) emitted=\(transcriptsEmitted) rms=\(String(format: "%.5f", rms)) restarts=\(restartCount)")
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
    /// Rate-limited because the recognizer can fire "No speech detected" repeatedly with
    /// almost no time between callbacks (especially during periods of silence). Without a
    /// cap we'd loop indefinitely and saturate the main thread with log appends.
    private func scheduleRestart() {
        mutex.lock()
        guard !isFinished else { mutex.unlock(); return }
        let now = Date()
        recentRestartTimestamps = recentRestartTimestamps.filter { now.timeIntervalSince($0) < Self.restartWindow }
        let recentCount = recentRestartTimestamps.count
        recentRestartTimestamps.append(now)
        restartCount += 1
        mutex.unlock()

        // Don't permanently give up. SFSpeech's "No speech detected" can fire repeatedly
        // during silence; once audio resumes we should still recognize. Slow down restart
        // attempts when the error rate is high but never close the door.
        let delay: TimeInterval = recentCount >= Self.maxRestartsPerWindow ? 5.0 : Self.restartDelay
        if recentCount >= Self.maxRestartsPerWindow {
            wpInfo("Transcriber.\(self.channel) backing off restart attempts (rate cap hit, retrying in \(Int(delay))s)")
        }

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self?.actuallyRestart()
        }
    }

    private func actuallyRestart() {
        mutex.lock()
        guard !isFinished else { mutex.unlock(); return }
        let next = SFSpeechAudioBufferRecognitionRequest()
        next.shouldReportPartialResults = true
        next.requiresOnDeviceRecognition = false
        next.taskHint = .dictation
        request = next
        task?.cancel()
        task = nil
        mutex.unlock()
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
