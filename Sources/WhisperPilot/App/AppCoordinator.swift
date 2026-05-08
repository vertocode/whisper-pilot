import AVFoundation
import Combine
import CoreGraphics
import Foundation
import ImageIO
import OSLog
import ScreenCaptureKit
import UniformTypeIdentifiers

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
    private var pausedObserver: AnyCancellable?
    private var intervalObserver: AnyCancellable?
    private var autoSendTimer: Timer?
    private var lastAutoSendTranscriptCount: Int = 0

    private(set) var isRunning = false
    private(set) var currentSession: SessionMeta?

    init() {
        // Wire up the AI provider eagerly if a key already exists, so the composer works
        // before/without ever clicking ▶ Play. AI prompts are independent of listening.
        if let key = settings.geminiAPIKey, !key.isEmpty {
            aiProvider = GeminiProvider(apiKey: key, model: settings.geminiModel)
        }

        settingsObserver = settings.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.refreshDerivedState() }
        }

        intervalObserver = settings.$autoSendInterval
            .removeDuplicates()
            .sink { [weak self] _ in self?.restartAutoSendTimer() }

        pausedObserver = overlayState.$isAIPaused
            .removeDuplicates()
            .sink { [weak self] _ in
                // The toggle button itself is the visual indicator — no system note needed.
                self?.restartAutoSendTimer()
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
        // Sync the live `aiProvider` reference with the current API key. Runs whether or
        // not we're actively listening — composer prompts work independently.
        let key = settings.geminiAPIKey ?? ""
        if !key.isEmpty {
            if aiProvider == nil {
                aiProvider = GeminiProvider(apiKey: key, model: settings.geminiModel)
            }
        } else if aiProvider != nil {
            aiProvider = nil
            overlayState.appendSystemNote("ℹ️ Gemini key removed. Transcription still running; AI features disabled.", category: .general)
        }

        if !isRunning {
            switch overlayState.status {
            case .needsAPIKey:
                if !key.isEmpty { overlayState.status = .idle }
            case .needsPermission(.microphone):
                if !settings.captureMicrophone || permissions.snapshot.microphone == .granted {
                    overlayState.status = .idle
                }
            default:
                break
            }
        }
    }

    // MARK: - Lifecycle

    func startListening() async {
        guard !isRunning else {
            wpInfo("[Coordinator] startListening: already running, skipping")
            return
        }
        wpInfo("[Coordinator] ▶ startListening")
        await permissions.refresh()
        overlayState.permissionStatus = permissions.snapshot

        let priorScreenRecording = permissions.snapshot.screenRecording
        do {
            _ = try await SCShareableContent.current
            permissions.markScreenRecordingGranted()
            overlayState.permissionStatus = permissions.snapshot
            wpInfo("[Coordinator] ✓ Screen Recording probe passed")
            // Resolution success goes to diagnostics only — the user clicked Play and got
            // green status. No need to clutter the chat lane.
            if priorScreenRecording != .granted {
                wpInfo("Screen Recording permission detected on this run")
            }
        } catch {
            wpError("Screen Recording probe failed: \(error.localizedDescription)")
            overlayState.appendSystemNote("⚠️ Screen Recording permission not granted — opening System Settings.", category: .general)
            overlayState.status = .needsPermission(.screenRecording)
            await permissions.requestScreenRecording()
            return
        }

        if settings.captureMicrophone, permissions.snapshot.microphone != .granted {
            wpInfo("[Coordinator] microphone requested, not authorized — prompting")
            await permissions.requestMicrophone()
            if permissions.snapshot.microphone == .granted {
                wpInfo("Microphone permission granted; continuing pipeline")
                // fall through to start the pipeline so the user doesn't have to click Play again
            } else {
                overlayState.appendSystemNote("⚠️ Microphone permission was not granted. Either disable microphone capture in Settings or grant access via System Settings → Privacy & Security → Microphone.", category: .general)
                overlayState.status = .needsPermission(.microphone)
                return
            }
        }

        // Transcription does NOT depend on the LLM — it runs locally via SFSpeechRecognizer.
        // We deliberately allow listening without a Gemini API key so users can use the
        // app as a standalone transcriber, or debug the audio pipeline independently of
        // any AI integration. AI features (detected-question triggers, auto-send, the
        // composer) noop until a key is present.
        wpInfo("[Coordinator] starting modules")
        let transcriber = AppleSpeechTranscriber(locale: settings.locale)
        self.transcriber = transcriber

        if let key = settings.geminiAPIKey, !key.isEmpty {
            // refreshDerivedState already keeps aiProvider in sync; nothing to do here.
        } else {
            wpInfo("[Coordinator] no Gemini key — transcription-only mode")
            overlayState.appendSystemNote("ℹ️ Transcription is running. Add a Gemini API key in Settings to enable AI suggestions.", category: .general)
        }

        do {
            try await transcriber.start()
            wpInfo("[Coordinator] transcriber.start OK")
            try await systemCapture.start()
            wpInfo("[Coordinator] systemCapture.start OK")
            if settings.captureMicrophone {
                try await micCapture.start()
                wpInfo("[Coordinator] micCapture.start OK")
            } else {
                wpInfo("[Coordinator] microphone capture disabled in settings")
            }
        } catch {
            wpError("Pipeline start failed: \(error.localizedDescription)")
            overlayState.status = .error(error.localizedDescription)
            return
        }

        startPipeline(transcriber: transcriber, ai: aiProvider)
        restartAutoSendTimer()

        isRunning = true
        overlayState.status = .listening
        wpInfo("[Coordinator] ✓ Listening")
        startNoFramesWatchdog()
    }

    /// Surfaces visible warnings when the audio or transcription pipeline is silent. Two
    /// staged checks: 6 seconds for "is audio flowing at all", then 14 seconds to confirm
    /// transcripts started. The 14s gate fires only if audio is flowing — that's the case
    /// where SFSpeechRecognizer is the bottleneck and the user needs a concrete next step.
    private func startNoFramesWatchdog() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, self.isRunning else { return }
            if self.overlayState.audioFrameCount == 0 {
                let message = "No audio frames after 6 seconds. ScreenCaptureKit started but isn't delivering audio. Try playing a video, switching audio output device, or stop and start listening again."
                wpWarn(message)
                self.overlayState.appendSystemNote("⚠️ \(message)", category: .transcript)
            } else if self.overlayState.transcriptCount == 0 {
                let message = "Audio is flowing (\(self.overlayState.audioFrameCount) frames) but no transcripts yet. Speak audibly or play a clearly-spoken video."
                wpWarn(message)
                self.overlayState.appendSystemNote("⚠️ \(message)", category: .transcript)
            }
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 14_000_000_000)
            guard let self, self.isRunning else { return }
            if self.overlayState.audioFrameCount > 0, self.overlayState.transcriptCount == 0 {
                let locale = self.settings.localeIdentifier
                let message = "Still no transcripts after 14 seconds (locale=\(locale)). Likely causes: (a) Speech Recognition not authorized — check System Settings → Privacy & Security → Speech Recognition; (b) wrong locale — open Settings → General → Locale and try \"en-US\"; (c) the audio is silent or non-speech. Open the 🐞 Diagnostics panel to see RMS values per buffer."
                wpWarn(message)
                self.overlayState.appendSystemNote("⚠️ \(message)", category: .transcript)
            }
        }
    }

    func stopListening() async {
        guard isRunning || transcriber != nil else { return }
        log.info("⏹ stopListening")
        for task in consumerTasks { task.cancel() }
        consumerTasks.removeAll()
        inFlightCompletion?.cancel()
        inFlightCompletion = nil
        autoSendTimer?.invalidate()
        autoSendTimer = nil

        await systemCapture.stop()
        await micCapture.stop()
        transcriber?.stop()
        transcriber = nil
        aiProvider = nil

        isRunning = false
        overlayState.status = .idle
        overlayState.audioFrameCount = 0
        overlayState.transcriptCount = 0
    }

    func toggleListening() async {
        if isRunning { await stopListening() } else { await startListening() }
    }

    func toggleAIPaused() {
        overlayState.isAIPaused.toggle()
    }

    /// Activate a session — either fresh or resumed. On resume we hand the prior
    /// transcript + chat markdown to the conversation context so the AI sees them on the
    /// next prompt; we do NOT replay them into the live transcript lane (that lane shows
    /// new content only). A system note tells the user which session they're in.
    func useSession(_ session: SessionMeta, resumed: Bool) async {
        currentSession = session
        if resumed {
            let transcript = await SessionStore.shared.loadTranscriptMarkdown(session.id)
            let chat = await SessionStore.shared.loadChatMarkdown(session.id)
            await context.seedFromMarkdown(transcript: transcript, chat: chat)
            // No system note — the user just picked this session, they know what they did.
        } else {
            overlayState.clearChat()
            await context.reset()
        }
    }

    /// User typed something in the composer. Always honored even when AI is paused.
    /// When `withScreenshot` is true, we capture the current display via ScreenCaptureKit
    /// and ship it as a multimodal `inline_data` part so the model can reason about what
    /// the user is looking at.
    func sendUserPrompt(_ raw: String, withScreenshot: Bool = false) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let ai = aiProvider else {
            overlayState.appendSystemNote("⚠️ Add a Gemini API key in Settings to use the AI.", category: .ai)
            return
        }
        let displayedText = withScreenshot ? "\(text) 📸" : text
        overlayState.appendUserMessage(displayedText)
        persistChatTurn(role: "You", text: text + (withScreenshot ? "\n_(screenshot attached)_" : ""))
        let history = chatHistorySnapshot(excludingLast: true)

        Task { [weak self] in
            guard let self else { return }
            let snapshot = await self.context.snapshotWithPrior()
            var prompt = PromptBuilder.buildUserQuery(
                context: snapshot,
                history: history,
                query: text,
                style: self.settings.responseStyle,
                withScreenshot: withScreenshot
            )

            if withScreenshot {
                if let imageData = await self.captureScreenJPEG() {
                    prompt.imageJPEGBase64 = imageData.base64EncodedString()
                    wpInfo("Screenshot captured (\(imageData.count) bytes)")
                } else {
                    self.overlayState.appendSystemNote("⚠️ Couldn't capture screen — sending without it. Make sure Screen Recording permission is granted.", category: .ai)
                    wpWarn("Screenshot capture failed; falling back to text-only")
                }
            }
            await self.runCompletion(prompt: prompt, ai: ai, origin: .userPrompt)
        }
    }

    /// Captures the primary display via ScreenCaptureKit, downsamples to ≤1280 px wide so
    /// we don't ship 4K frames to the model, and JPEG-encodes at quality 0.7. Returns nil
    /// if Screen Recording permission isn't granted or no display is shareable.
    private func captureScreenJPEG(maxWidth: Int = 1280, quality: CGFloat = 0.7) async -> Data? {
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else { return nil }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let resized = downsample(cgImage, maxWidth: maxWidth) ?? cgImage
            return jpegData(from: resized, quality: quality)
        } catch {
            log.error("Screenshot capture failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func downsample(_ image: CGImage, maxWidth: Int) -> CGImage? {
        let width = image.width
        guard width > maxWidth else { return image }
        let scale = CGFloat(maxWidth) / CGFloat(width)
        let newWidth = maxWidth
        let newHeight = Int((CGFloat(image.height) * scale).rounded())
        guard let space = image.colorSpace,
              let context = CGContext(
                data: nil,
                width: newWidth,
                height: newHeight,
                bitsPerComponent: image.bitsPerComponent,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: image.bitmapInfo.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage()
    }

    private func jpegData(from cgImage: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private func persistChatTurn(role: String, text: String) {
        guard let sessionID = currentSession?.id else { return }
        Task {
            await SessionStore.shared.appendChatTurn(role: role, text: text, at: Date(), to: sessionID)
        }
    }

    /// Snapshots the recent assistant↔user chat as `[ChatTurn]` for prompt context. Drops
    /// system notes (those are user-facing UI affordances, not part of the conversation).
    private func chatHistorySnapshot(excludingLast: Bool) -> [ChatTurn] {
        var msgs = overlayState.messages
        if excludingLast, !msgs.isEmpty {
            msgs.removeLast()
        }
        return msgs.compactMap { msg -> ChatTurn? in
            switch msg.role {
            case .user: return ChatTurn(role: .user, text: msg.text)
            case .assistant where !msg.text.isEmpty: return ChatTurn(role: .assistant, text: msg.text)
            default: return nil
            }
        }
    }

    // MARK: - Wiring

    private func startPipeline(transcriber: TranscriptionProvider, ai: AIProvider?) {
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
            var framesProcessed = 0
            for await frame in mixer.output {
                framesProcessed += 1
                if framesProcessed == 1 {
                    wpInfo("Pipeline: first audio frame received (channel=\(frame.channel))")
                    Task { @MainActor [weak self] in
                        self?.overlayState.audioFrameCount = 1
                    }
                }
                if framesProcessed % 25 == 0 {
                    let count = framesProcessed
                    Task { @MainActor [weak self] in self?.overlayState.audioFrameCount = count }
                }
                let event = await vad.feed(frame)
                transcriber.feed(frame.buffer, channel: frame.channel)
                if let event {
                    wpInfo("VAD: \(event)")
                    await self?.handleVADEvent(event)
                }
            }
            wpInfo("Pipeline: mixer stream ended after \(framesProcessed) frames")
        })

        consumerTasks.append(Task { [weak self] in
            var transcriptsSeen = 0
            for await update in transcriber.transcripts {
                await buffer.apply(update)
                await context.absorb(update)
                let snapshot = await buffer.snapshot()
                self?.overlayState.transcript = snapshot
                transcriptsSeen += 1
                self?.overlayState.transcriptCount = transcriptsSeen
                if transcriptsSeen == 1 {
                    wpInfo("First transcript update received")
                }

                // Persist finalized transcript lines to the active session's transcript.md
                if update.isFinal,
                   let sessionID = self?.currentSession?.id,
                   !update.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    Task {
                        await SessionStore.shared.appendTranscriptLine(
                            channel: update.channel,
                            text: update.text,
                            at: update.timestamp,
                            to: sessionID
                        )
                    }
                }
            }
        })

        consumerTasks.append(Task { [weak self] in
            for await trigger in engine.events {
                guard let self else { return }
                if self.overlayState.isAIPaused {
                    wpInfo("[Coordinator] trigger fired but AI is paused — skipping")
                    continue
                }
                guard let liveAI = self.aiProvider else {
                    wpInfo("[Coordinator] trigger fired but no Gemini key — skipping")
                    continue
                }
                self.log.info("→ Trigger fired, building prompt")
                self.overlayState.status = .thinking
                let snapshot = await self.context.snapshotWithPrior()
                let style = self.settings.responseStyle
                let history = self.chatHistorySnapshot(excludingLast: false)
                let prompt = PromptBuilder.build(
                    context: snapshot,
                    history: history,
                    question: trigger.text,
                    style: style
                )
                await self.runCompletion(prompt: prompt, ai: liveAI, origin: .detectedQuestion)
            }
        })
    }

    private func handleVADEvent(_ event: VoiceActivityEvent) async {
        await triggerEngine.absorb(event)
        if let last = await transcriptBuffer.lastFinalized() {
            await triggerEngine.consider(segment: last)
        }
    }

    private func runCompletion(prompt: Prompt, ai: AIProvider, origin: ChatMessage.Origin) async {
        inFlightCompletion?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            let messageId = self.overlayState.beginAssistantStream(origin: origin)
            self.overlayState.status = .streaming
            do {
                var deltaCount = 0
                for try await delta in ai.streamCompletion(prompt: prompt) {
                    if Task.isCancelled { break }
                    deltaCount += 1
                    self.overlayState.appendDelta(to: messageId, delta)
                }
                self.log.info("Stream complete (\(deltaCount) deltas)")
                self.overlayState.finishAssistant(id: messageId)
                self.overlayState.status = .listening
                if let finalText = self.overlayState.messages.first(where: { $0.id == messageId })?.text,
                   !finalText.isEmpty {
                    self.persistChatTurn(role: "Assistant", text: finalText)
                }
            } catch is CancellationError {
                self.overlayState.finishAssistant(id: messageId)
            } catch {
                let message = error.localizedDescription
                wpError("AI stream failed: \(message)")
                self.overlayState.finishAssistant(id: messageId)
                self.overlayState.status = .error(message)
                self.overlayState.appendSystemNote("⚠️ \(message)", category: .ai)
            }
        }
        inFlightCompletion = task
        await task.value
    }

    // MARK: - Auto-send

    private func restartAutoSendTimer() {
        autoSendTimer?.invalidate()
        autoSendTimer = nil
        guard isRunning, !overlayState.isAIPaused, let interval = settings.autoSendInterval.seconds else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runAutoSend() }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoSendTimer = timer
        lastAutoSendTranscriptCount = overlayState.transcriptCount
        wpInfo("[Coordinator] auto-send timer scheduled every \(interval)s")
    }

    private func runAutoSend() {
        guard isRunning, !overlayState.isAIPaused else { return }
        guard let ai = aiProvider else { return }
        // Skip the tick if no new transcript content has accumulated since the last send.
        let currentCount = overlayState.transcriptCount
        if currentCount <= lastAutoSendTranscriptCount {
            wpInfo("[Coordinator] auto-send tick skipped — no new transcripts since last send")
            return
        }
        lastAutoSendTranscriptCount = currentCount
        wpInfo("[Coordinator] auto-send tick firing")
        Task { [weak self] in
            guard let self else { return }
            let snapshot = await self.context.snapshotWithPrior()
            let history = self.chatHistorySnapshot(excludingLast: false)
            let prompt = PromptBuilder.buildAutoSend(context: snapshot, history: history, style: self.settings.responseStyle)
            await self.runCompletion(prompt: prompt, ai: ai, origin: .autoSend)
        }
    }
}
