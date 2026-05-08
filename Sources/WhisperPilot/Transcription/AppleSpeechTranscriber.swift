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
        log.info("Starting transcriber for locale=\(self.locale.identifier, privacy: .public)…")
        try await ensureAuthorization()
        log.info("✓ Speech recognition authorized")
        systemPipe = try ChannelPipe(channel: .system, locale: locale, sink: continuation, log: log)
        micPipe = try ChannelPipe(channel: .microphone, locale: locale, sink: continuation, log: log)
        log.info("✓ Both channel pipes started")
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

    init(channel: AudioChannel, locale: Locale, sink: AsyncStream<TranscriptUpdate>.Continuation, log: Logger) throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            log.error("[\(String(describing: channel), privacy: .public)] No SFSpeechRecognizer for locale \(locale.identifier, privacy: .public)")
            throw TranscriberError.unavailable(locale.identifier)
        }
        guard recognizer.isAvailable else {
            log.error("[\(String(describing: channel), privacy: .public)] SFSpeechRecognizer not currently available for \(locale.identifier, privacy: .public)")
            throw TranscriberError.unavailable(locale.identifier)
        }
        self.channel = channel
        self.recognizer = recognizer
        self.sink = sink
        self.log = log
        self.request = SFSpeechAudioBufferRecognitionRequest()
        self.request.shouldReportPartialResults = true
        // Only require on-device when the recognizer actually supports it for this locale.
        self.request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.request.taskHint = .dictation
        log.info("[\(String(describing: channel), privacy: .public)] ChannelPipe ready (onDevice=\(recognizer.supportsOnDeviceRecognition))")
        startTask()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request.append(buffer)
        buffersAppended += 1
        if buffersAppended == 1 {
            log.info("[\(String(describing: self.channel), privacy: .public)] First buffer appended to recognizer")
        } else if buffersAppended % 200 == 0 {
            log.debug("[\(String(describing: self.channel), privacy: .public)] Buffers appended: \(self.buffersAppended, privacy: .public), transcripts emitted: \(self.transcriptsEmitted, privacy: .public)")
        }
    }

    func finish() {
        request.endAudio()
        task?.cancel()
        task = nil
        log.info("[\(String(describing: self.channel), privacy: .public)] ChannelPipe finished. Appended=\(self.buffersAppended), emitted=\(self.transcriptsEmitted)")
    }

    private func startTask() {
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
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
                    log.info("[\(String(describing: self.channel), privacy: .public)] First transcript: \"\(update.text, privacy: .public)\" final=\(update.isFinal)")
                }
                if result.isFinal {
                    log.info("[\(String(describing: self.channel), privacy: .public)] Final segment: \"\(update.text, privacy: .public)\"")
                    segmentId = UUID()
                }
            }
            if let error {
                log.error("[\(String(describing: self.channel), privacy: .public)] Recognition error: \(String(describing: error), privacy: .public)")
                segmentId = UUID()
            }
        }
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
