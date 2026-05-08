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

    private var systemPipe: ChannelPipe?
    private var micPipe: ChannelPipe?

    init(locale: Locale) {
        self.locale = locale
        var capturedContinuation: AsyncStream<TranscriptUpdate>.Continuation!
        self.transcripts = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation
        super.init()
    }

    func start() async throws {
        print("[WP][Transcriber] start() begin (locale=\(locale.identifier))")
        log.info("Starting transcriber for locale=\(self.locale.identifier, privacy: .public)…")
        try await ensureAuthorization()
        print("[WP][Transcriber] auth ok")
        systemPipe = try ChannelPipe(channel: .system, locale: locale, sink: continuation, log: log)
        micPipe = try ChannelPipe(channel: .microphone, locale: locale, sink: continuation, log: log)
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
    private var segmentId = UUID()
    private var buffersAppended: Int = 0
    private var transcriptsEmitted: Int = 0
    private var restartCount: Int = 0
    private var isFinished: Bool = false
    private let mutex = NSLock()

    init(channel: AudioChannel, locale: Locale, sink: AsyncStream<TranscriptUpdate>.Continuation, log: Logger) throws {
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
        self.request = SFSpeechAudioBufferRecognitionRequest()
        self.request.shouldReportPartialResults = true
        // Permissive: prefer on-device, but allow server fallback. Setting this to `true`
        // when the locale's on-device model isn't fully ready causes the task to silently
        // produce no output — exactly the symptom we kept hitting. Always-false here means
        // recognition will use on-device when available, and Apple's servers when not.
        self.request.requiresOnDeviceRecognition = false
        self.request.taskHint = .dictation
        wpInfo("Transcriber.\(channel) ready (locale=\(locale.identifier), onDeviceSupported=\(recognizer.supportsOnDeviceRecognition), requiresOnDevice=false)")
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

    private func startTask() {
        var firstCallback = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if firstCallback {
                wpInfo("Transcriber.\(channel) recognitionTask first callback (result=\(result != nil), error=\(error != nil))")
                firstCallback = false
            }
            if let result {
                let update = TranscriptUpdate(
                    id: segmentId,
                    text: result.bestTranscription.formattedString,
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
                wpError("Transcriber.\(channel) recognition error: \(error.localizedDescription) — restarting recognizer")
                segmentId = UUID()
                self.restartIfNeeded()
            }
        }
        wpInfo("Transcriber.\(channel) recognitionTask started (restart#\(restartCount))")
    }

    /// `SFSpeechRecognitionTask` enters a terminal state after errors like "No speech
    /// detected" — every subsequent `request.append(buffer:)` is silently ignored.
    /// Recovery is to drop the request, build a fresh one, and start a new task. Called
    /// from the recognition callback (background queue), so we serialize via `mutex`.
    private func restartIfNeeded() {
        mutex.lock()
        guard !isFinished else { mutex.unlock(); return }
        restartCount += 1
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
