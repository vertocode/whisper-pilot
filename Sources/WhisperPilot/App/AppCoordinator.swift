import AVFoundation
import Combine
import CoreGraphics
import Foundation
import ImageIO
import OSLog
import ScreenCaptureKit
import Speech
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
    /// When Core Audio Process Tap is in use, this stream is its output. The pipeline
    /// reads from whichever of `processTapFrames` or `systemCapture.frames` is active.
    private var processTapFrames: AsyncStream<AudioFrame>?
    private var processTapStop: (() -> Void)?
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

        // Surface what audio devices the OS is presenting before we start capture, so the
        // user can immediately see in Diagnostics whether they're using the device they
        // expected (built-in vs USB vs Bluetooth vs aggregate vs virtual).
        if let out = MicrophoneCapture.defaultOutputDeviceInfo() {
            wpInfo("Default output device: \(out.name ?? "unknown") (id=\(out.id))")
        }
        if let mic = MicrophoneCapture.defaultInputDeviceInfo() {
            wpInfo("Default input device: \(mic.name ?? "unknown") (id=\(mic.id))")
        }

        // Audio capture path. Prefer Core Audio Process Taps when available (macOS 14.4+):
        // pure audio capture, no Screen Recording prompt, no "screen is being recorded"
        // mode that breaks Live Captions and confuses some macOS audio routing setups.
        // ScreenCaptureKit remains the fallback for older OSes or when the tap fails.
        if #available(macOS 14.4, *) {
            let pt = ProcessAudioCapture()
            do {
                try await pt.start()
                processTapFrames = pt.frames
                processTapStop = { pt.stop() }
                wpInfo("[Coordinator] ✓ Using Core Audio Process Tap (audio-only, no screen recording)")
            } catch {
                wpWarn("Process Tap unavailable (\(error.localizedDescription)); falling back to ScreenCaptureKit")
            }
        }

        if processTapFrames == nil {
            // SCK fallback path — needs Screen Recording permission.
            let priorScreenRecording = permissions.snapshot.screenRecording
            do {
                _ = try await SCShareableContent.current
                permissions.markScreenRecordingGranted()
                overlayState.permissionStatus = permissions.snapshot
                wpInfo("[Coordinator] ✓ Screen Recording probe passed (SCK fallback)")
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
            if processTapFrames == nil {
                try await systemCapture.start()
                wpInfo("[Coordinator] systemCapture.start OK (SCK)")
            }
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
                let method = self.processTapFrames != nil ? "Core Audio Process Tap" : "ScreenCaptureKit"
                let outName = MicrophoneCapture.defaultOutputDeviceInfo()?.name ?? "unknown"
                let message = "No audio frames after 6 seconds. \(method) started but isn't delivering audio. Default output device is “\(outName)”. Check that audio is actually playing through that device — virtual / aggregate / Bluetooth devices sometimes bypass the macOS audio mixdown that we capture from."
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

        if let stop = processTapStop {
            stop()
            processTapStop = nil
            processTapFrames = nil
        } else {
            await systemCapture.stop()
        }
        await micCapture.stop()
        transcriber?.stop()
        transcriber = nil
        // aiProvider stays alive across stop/start so the composer keeps working.

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

    // MARK: - Self-test

    /// Generates speech with `AVSpeechSynthesizer`, feeds the resulting audio buffers
    /// directly into a fresh `AppleSpeechTranscriber`, and reports whether transcripts come
    /// back. This exercises the recognition pipeline in isolation from audio capture, so
    /// it answers the question: "is the recognizer broken, or is audio capture broken?"
    /// User-runnable from the Diagnostics panel.
    func runRecognitionSelfTest() async {
        let phrase = "Hello world. This is the Whisper Pilot self test."
        overlayState.appendSystemNote("🧪 Running recognition self-test…", category: .transcript)
        wpInfo("Self-test starting: synthesizing \"\(phrase)\"")

        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: break
        case .notDetermined:
            let granted: Bool = await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
            }
            if !granted {
                overlayState.appendSystemNote("❌ Self-test failed: Speech Recognition permission was not granted. Re-run after enabling it in System Settings → Privacy & Security → Speech Recognition.", category: .transcript)
                return
            }
        case .denied, .restricted:
            overlayState.appendSystemNote("❌ Self-test failed: Speech Recognition is denied or restricted. Enable it in System Settings → Privacy & Security → Speech Recognition.", category: .transcript)
            return
        @unknown default:
            overlayState.appendSystemNote("❌ Self-test failed: unknown authorization state.", category: .transcript)
            return
        }

        let testTranscriber = AppleSpeechTranscriber(locale: settings.locale)
        do {
            try await testTranscriber.start()
        } catch {
            overlayState.appendSystemNote("❌ Self-test failed: couldn't start recognizer (\(error.localizedDescription)).", category: .transcript)
            return
        }

        // Stream collector
        actor Collector {
            var text = ""
            func set(_ t: String) { text = t }
            func snapshot() -> String { text }
        }
        let collector = Collector()
        let collectorTask = Task {
            for await update in testTranscriber.transcripts {
                await collector.set(update.text)
                if update.isFinal { return }
            }
        }

        // Synthesize and feed
        let synth = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: phrase)
        utterance.rate = 0.45
        utterance.voice = AVSpeechSynthesisVoice(language: settings.localeIdentifier)
            ?? AVSpeechSynthesisVoice(language: "en-US")

        let canonical = CanonicalAudioFormat.make()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var done = false
            var converter: AVAudioConverter?
            var sourceFormat: AVAudioFormat?
            synth.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    if !done { done = true; cont.resume() }
                    return
                }
                if sourceFormat?.isEqual(pcm.format) != true {
                    sourceFormat = pcm.format
                    converter = AVAudioConverter(from: pcm.format, to: canonical)
                }
                guard let converter else { return }
                let outputCapacity = AVAudioFrameCount(Double(pcm.frameLength) * canonical.sampleRate / pcm.format.sampleRate) + 1024
                guard let out = AVAudioPCMBuffer(pcmFormat: canonical, frameCapacity: outputCapacity) else { return }
                var error: NSError?
                var consumed = false
                converter.convert(to: out, error: &error) { _, status in
                    if consumed { status.pointee = .endOfStream; return nil }
                    consumed = true
                    status.pointee = .haveData
                    return pcm
                }
                if error == nil, out.frameLength > 0 {
                    testTranscriber.feed(out, channel: .system)
                }
            }
        }

        // Give SFSpeech a moment to flush partial → final
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        collectorTask.cancel()
        testTranscriber.stop()

        let result = await collector.snapshot()
        wpInfo("Self-test result: \"\(result)\"")
        if result.isEmpty {
            overlayState.appendSystemNote("❌ Self-test failed: recognizer received synthesized speech but produced no transcripts. The recognizer pipeline isn't working — likely a Speech Recognition permission or locale model issue.", category: .transcript)
        } else {
            overlayState.appendSystemNote("✅ Self-test passed: recognizer produced \"\(result)\". The recognition pipeline works correctly. If live transcription still fails, the bug is in audio capture / routing — your default output device is likely not exposing audio to the macOS mixdown that we capture from.", category: .transcript)
        }
    }

    // MARK: - Wiring

    private func startPipeline(transcriber: TranscriptionProvider, ai: AIProvider?) {
        let mixer = audioMixer
        let vad = vad
        let buffer = transcriptBuffer
        let context = context
        let engine = triggerEngine

        // Source the system audio from whichever capture path is currently active. Process
        // Tap is preferred (audio-only, set up above when on macOS 14.4+); SCK is the fallback.
        let systemStream = processTapFrames ?? systemCapture.frames
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
