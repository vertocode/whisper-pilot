import AVFoundation
import Foundation
import OSLog

/// Owns every long-lived module. The only place that knows about concrete types.
/// Public surface is intentionally small; views and the menu bar talk through `OverlayState`,
/// `SettingsStore`, and a handful of high-level start/stop methods.
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

    private(set) var isRunning = false

    func bootstrap() async {
        await permissions.refresh()
        overlayState.permissionStatus = permissions.snapshot
        overlayState.status = .idle
    }

    func shutdown() async {
        await stopListening()
    }

    // MARK: - Lifecycle

    func startListening() async {
        guard !isRunning else { return }
        await permissions.refresh()
        overlayState.permissionStatus = permissions.snapshot

        guard permissions.snapshot.screenRecording == .granted else {
            overlayState.status = .needsPermission(.screenRecording)
            await permissions.requestScreenRecording()
            return
        }

        if settings.captureMicrophone, permissions.snapshot.microphone != .granted {
            overlayState.status = .needsPermission(.microphone)
            await permissions.requestMicrophone()
            return
        }

        guard let key = settings.geminiAPIKey, !key.isEmpty else {
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
            }
        } catch {
            log.error("Failed to start capture: \(String(describing: error), privacy: .public)")
            overlayState.status = .error(error.localizedDescription)
            return
        }

        startPipeline(transcriber: transcriber, ai: ai)

        isRunning = true
        overlayState.status = .listening
    }

    func stopListening() async {
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

        let systemStream = systemCapture.frames
        let micStream = micCapture.frames

        consumerTasks.append(Task.detached {
            await mixer.run(systemFrames: systemStream, micFrames: micStream)
        })

        consumerTasks.append(Task.detached { [weak self] in
            for await frame in mixer.output {
                let event = await vad.feed(frame)
                transcriber.feed(frame.buffer, channel: frame.channel)
                if let event {
                    await self?.handleVADEvent(event)
                }
            }
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
                for try await delta in ai.streamCompletion(prompt: prompt) {
                    if Task.isCancelled { break }
                    self.overlayState.appendResponse(delta)
                }
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
