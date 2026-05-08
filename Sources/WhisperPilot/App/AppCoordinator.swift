import AVFoundation
import Combine
import Foundation
import OSLog
import ScreenCaptureKit

/// Owns every long-lived module. The only place that knows about concrete types.
@MainActor
final class AppCoordinator {
    let settings = SettingsStore()
    let permissions = PermissionsManager()
    let overlayState = OverlayState()

    private let log = Logger(subsystem: "com.whisperpilot.app", category: "Coordinator")

    private let audioMixer = AudioMixer()
    private let systemCapture = SystemAudioCapture()
    private let micCapture = MicrophoneCapture()
    private let vad = VoiceActivityDetector()
    private let transcriptBuffer = TranscriptBuffer()
    private let context = ConversationContext()
    private let triggerEngine = TriggerEngine()

    private var transcriber: TranscriptionProvider?
    private var aiProvider: AIProvider?

    private var consumerTasks: [Task<Void, Never>] = []
    private var inFlightCompletion: Task<Void, Never>?
    private var settingsObserver: AnyCancellable?

    private(set) var isRunning = false

    init() {
        // When the user types in their API key (or relevant settings change), recover from
        // a stuck `.needsAPIKey` state so they don't have to click ▶ for the banner to clear.
        settingsObserver = settings.objectWillChange.sink { [weak self] in
            // objectWillChange fires before the value is updated; defer to the next runloop tick.
            DispatchQueue.main.async { [weak self] in self?.refreshDerivedState() }
        }
    }

    func bootstrap() async {
        log.info("Bootstrap")
        await permissions.refresh()
        overlayState.permissionStatus = permissions.snapshot
        overlayState.status = .idle
        log.info("Permissions snapshot: mic=\(String(describing: self.permissions.snapshot.microphone), privacy: .public), screen=\(String(describing: self.permissions.snapshot.screenRecording), privacy: .public)")
    }

    func shutdown() async {
        log.info("Shutdown")
        await stopListening()
    }

    private func refreshDerivedState() {
        if isRunning { return }
        switch overlayState.status {
        case .needsAPIKey:
            if let key = settings.geminiAPIKey, !key.isEmpty {
                overlayState.status = .idle
            }
        case .needsPermission(.microphone):
            if !settings.captureMicrophone || permissions.snapshot.microphone == .granted {
                overlayState.status = .idle
            }
        default:
            break
        }
    }

    // MARK: - Lifecycle

    func startListening() async {
        guard !isRunning else { log.info("startListening: already running"); return }
        log.info("▶ startListening")
        await permissions.refresh()
        overlayState.permissionStatus = permissions.snapshot

        // Probe Screen Recording via the actual ScreenCaptureKit API (the legacy
        // `CGPreflightScreenCaptureAccess` caches at process launch and can stay stuck on
        // "denied").
        do {
            _ = try await SCShareableContent.current
            permissions.markScreenRecordingGranted()
            overlayState.permissionStatus = permissions.snapshot
            log.info("✓ Screen Recording probe passed")
        } catch {
            log.error("✘ Screen Recording probe failed: \(String(describing: error), privacy: .public)")
            overlayState.status = .needsPermission(.screenRecording)
            await permissions.requestScreenRecording()
            return
        }

        if settings.captureMicrophone, permissions.snapshot.microphone != .granted {
            log.info("Microphone capture requested but not authorized; prompting")
            overlayState.status = .needsPermission(.microphone)
            await permissions.requestMicrophone()
            return
        }

        guard let key = settings.geminiAPIKey, !key.isEmpty else {
            log.error("✘ No Gemini API key configured")
            overlayState.status = .needsAPIKey
            return
        }

        let transcriber = AppleSpeechTranscriber(locale: settings.locale)
        let ai = GeminiProvider(apiKey: key, model: settings.geminiModel)
        self.transcriber = transcriber
        self.aiProvider = ai

        do {
            try await transcriber.start()
            try await systemCapture.start()
            if settings.captureMicrophone {
                try await micCapture.start()
            } else {
                log.info("Microphone capture disabled in settings")
            }
        } catch {
            log.error("✘ Pipeline start failed: \(String(describing: error), privacy: .public)")
            overlayState.status = .error(error.localizedDescription)
            return
        }

        startPipeline(transcriber: transcriber, ai: ai)

        isRunning = true
        overlayState.status = .listening
        log.info("✓ Listening")
    }

    func stopListening() async {
        guard isRunning || transcriber != nil else { return }
        log.info("⏹ stopListening")
        for task in consumerTasks { task.cancel() }
        consumerTasks.removeAll()
        inFlightCompletion?.cancel()
        inFlightCompletion = nil

        await systemCapture.stop()
        await micCapture.stop()
        transcriber?.stop()
        transcriber = nil
        aiProvider = nil

        isRunning = false
        overlayState.status = .idle
    }

    func toggleListening() async {
        if isRunning { await stopListening() } else { await startListening() }
    }

    // MARK: - Wiring

    private func startPipeline(transcriber: TranscriptionProvider, ai: AIProvider) {
        let mixer = audioMixer
        let vad = vad
        let buffer = transcriptBuffer
        let context = context
        let engine = triggerEngine
        let log = log

        let systemStream = systemCapture.frames
        let micStream = micCapture.frames

        consumerTasks.append(Task.detached {
            await mixer.run(systemFrames: systemStream, micFrames: micStream)
        })

        consumerTasks.append(Task.detached { [weak self] in
            var framesProcessed = 0
            for await frame in mixer.output {
                framesProcessed += 1
                if framesProcessed == 1 {
                    log.info("Pipeline: first mixer frame received (channel=\(String(describing: frame.channel), privacy: .public))")
                }
                let event = await vad.feed(frame)
                transcriber.feed(frame.buffer, channel: frame.channel)
                if let event {
                    log.info("VAD event: \(String(describing: event), privacy: .public)")
                    await self?.handleVADEvent(event)
                }
            }
            log.info("Pipeline: mixer stream ended after \(framesProcessed) frames")
        })

        consumerTasks.append(Task { [weak self] in
            for await update in transcriber.transcripts {
                await buffer.apply(update)
                await context.absorb(update)
                let snapshot = await buffer.snapshot()
                self?.overlayState.transcript = snapshot
            }
        })

        consumerTasks.append(Task { [weak self] in
            for await trigger in engine.events {
                guard let self else { return }
                self.log.info("→ Trigger fired, building prompt")
                self.overlayState.status = .thinking
                let snapshot = await context.snapshot()
                let style = self.settings.responseStyle
                let prompt = PromptBuilder.build(
                    context: snapshot,
                    question: trigger.text,
                    style: style
                )
                await self.runCompletion(prompt: prompt, ai: ai)
            }
        })
    }

    private func handleVADEvent(_ event: VoiceActivityEvent) async {
        await triggerEngine.absorb(event)
        if let last = await transcriptBuffer.lastFinalized() {
            await triggerEngine.consider(segment: last)
        }
    }

    private func runCompletion(prompt: Prompt, ai: AIProvider) async {
        inFlightCompletion?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            self.overlayState.beginResponse()
            do {
                var deltaCount = 0
                for try await delta in ai.streamCompletion(prompt: prompt) {
                    if Task.isCancelled { break }
                    deltaCount += 1
                    self.overlayState.appendResponse(delta)
                }
                self.log.info("Stream complete (\(deltaCount) deltas)")
                self.overlayState.endResponse()
                self.overlayState.status = .listening
            } catch is CancellationError {
                self.overlayState.endResponse()
            } catch {
                self.log.error("AI stream failed: \(String(describing: error), privacy: .public)")
                self.overlayState.endResponse()
                self.overlayState.status = .error(error.localizedDescription)
            }
        }
        inFlightCompletion = task
        await task.value
    }
}
