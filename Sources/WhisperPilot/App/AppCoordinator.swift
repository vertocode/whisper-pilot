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
        settingsObserver = settings.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.refreshDerivedState() }
        }

        intervalObserver = settings.$autoSendInterval
            .removeDuplicates()
            .sink { [weak self] _ in self?.restartAutoSendTimer() }

        pausedObserver = overlayState.$isAIPaused
            .removeDuplicates()
            .sink { [weak self] paused in
                if paused {
                    self?.overlayState.appendSystemNote("AI paused — only manual prompts will be sent.")
                } else {
                    self?.overlayState.appendSystemNote("AI active.")
                }
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
        guard !isRunning else {
            print("[WP][Coordinator] startListening: already running, skipping")
            return
        }
        print("[WP][Coordinator] ▶ startListening")
        await permissions.refresh()
        overlayState.permissionStatus = permissions.snapshot

        do {
            _ = try await SCShareableContent.current
            permissions.markScreenRecordingGranted()
            overlayState.permissionStatus = permissions.snapshot
            print("[WP][Coordinator] ✓ Screen Recording probe passed")
        } catch {
            print("[WP][Coordinator] ✘ Screen Recording probe failed: \(error.localizedDescription)")
            overlayState.status = .needsPermission(.screenRecording)
            await permissions.requestScreenRecording()
            return
        }

        if settings.captureMicrophone, permissions.snapshot.microphone != .granted {
            print("[WP][Coordinator] microphone requested, not authorized — prompting")
            overlayState.status = .needsPermission(.microphone)
            await permissions.requestMicrophone()
            return
        }

        guard let key = settings.geminiAPIKey, !key.isEmpty else {
            print("[WP][Coordinator] ✘ no Gemini API key")
            overlayState.status = .needsAPIKey
            return
        }

        print("[WP][Coordinator] all gates passed, starting modules")
        let transcriber = AppleSpeechTranscriber(locale: settings.locale)
        let ai = GeminiProvider(apiKey: key, model: settings.geminiModel)
        self.transcriber = transcriber
        self.aiProvider = ai

        do {
            try await transcriber.start()
            print("[WP][Coordinator] transcriber.start OK")
            try await systemCapture.start()
            print("[WP][Coordinator] systemCapture.start OK")
            if settings.captureMicrophone {
                try await micCapture.start()
                print("[WP][Coordinator] micCapture.start OK")
            } else {
                print("[WP][Coordinator] microphone capture disabled in settings")
            }
        } catch {
            print("[WP][Coordinator] ✘ Pipeline start failed: \(error.localizedDescription)")
            overlayState.status = .error(error.localizedDescription)
            return
        }

        startPipeline(transcriber: transcriber, ai: ai)
        restartAutoSendTimer()

        isRunning = true
        overlayState.status = .listening
        print("[WP][Coordinator] ✓ Listening")
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
            overlayState.appendSystemNote("Resumed session “\(session.displayName)”. Prior transcript and chat are now in AI context.")
        } else {
            overlayState.clearChat()
            await context.reset()
            overlayState.appendSystemNote("New session: \(session.displayName)")
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
            overlayState.appendSystemNote("Start listening first to enable the AI.")
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
                    print("[WP][Screenshot] captured \(imageData.count) bytes")
                } else {
                    self.overlayState.appendSystemNote("Couldn't capture screen — sending without it.")
                    print("[WP][Screenshot] capture failed; falling back to text-only")
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
            var framesProcessed = 0
            for await frame in mixer.output {
                framesProcessed += 1
                if framesProcessed == 1 {
                    print("[WP][Pipeline] FIRST mixer frame received (channel=\(frame.channel))")
                }
                if framesProcessed % 25 == 0 {
                    let count = framesProcessed
                    Task { @MainActor [weak self] in self?.overlayState.audioFrameCount = count }
                }
                let event = await vad.feed(frame)
                transcriber.feed(frame.buffer, channel: frame.channel)
                if let event {
                    print("[WP][VAD] \(event)")
                    await self?.handleVADEvent(event)
                }
            }
            print("[WP][Pipeline] mixer stream ended after \(framesProcessed) frames")
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
                    print("[WP][Coordinator] trigger fired but AI is paused — skipping")
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
                await self.runCompletion(prompt: prompt, ai: ai, origin: .detectedQuestion)
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
                self.log.error("AI stream failed: \(String(describing: error), privacy: .public)")
                self.overlayState.finishAssistant(id: messageId)
                self.overlayState.status = .error(error.localizedDescription)
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
        print("[WP][Coordinator] auto-send timer scheduled every \(interval)s")
    }

    private func runAutoSend() {
        guard isRunning, !overlayState.isAIPaused else { return }
        guard let ai = aiProvider else { return }
        // Skip the tick if no new transcript content has accumulated since the last send.
        let currentCount = overlayState.transcriptCount
        if currentCount <= lastAutoSendTranscriptCount {
            print("[WP][Coordinator] auto-send tick skipped — no new transcripts since last send")
            return
        }
        lastAutoSendTranscriptCount = currentCount
        print("[WP][Coordinator] auto-send tick firing")
        Task { [weak self] in
            guard let self else { return }
            let snapshot = await self.context.snapshotWithPrior()
            let history = self.chatHistorySnapshot(excludingLast: false)
            let prompt = PromptBuilder.buildAutoSend(context: snapshot, history: history, style: self.settings.responseStyle)
            await self.runCompletion(prompt: prompt, ai: ai, origin: .autoSend)
        }
    }
}
