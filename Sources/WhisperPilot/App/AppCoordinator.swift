import AVFoundation
import Combine
import CoreGraphics
import Foundation
import ImageIO
import os
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
    /// IDs of currently-displayed watchdog warnings, so we can dismiss them when the
    /// underlying problem resolves itself (e.g. audio frames start flowing).
    private var noFramesWarningID: UUID?
    private var noTranscriptsWarningID: UUID?
    /// Per-channel scheduled "cycle the recognizer" tasks, used to debounce VAD boundary
    /// events. Mid-sentence pauses (~0.4 s) shouldn't split a transcript line — only
    /// genuine end-of-utterance pauses should. A pending task is cancelled when speech
    /// resumes within the debounce window.
    private var pendingBoundaryTasks: [AudioChannel: Task<Void, Never>] = [:]
    private var settingsObserver: AnyCancellable?
    private var pausedObserver: AnyCancellable?
    private var intervalObserver: AnyCancellable?
    private var autoSendEnabledObserver: AnyCancellable?
    private var autoSendTimer: Timer?
    private var lastAutoSendTranscriptCount: Int = 0

    private(set) var isRunning = false
    /// Set for the duration of `startListening`. Prevents the user from double-clicking
    /// Play (or the disabled-but-still-clickable stop affordance) from re-entering startup
    /// while audio capture is mid-setup, which would leave duplicate captures running.
    private var isStartingUp = false
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

        autoSendEnabledObserver = settings.$autoSendEnabled
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
        guard !isRunning, !isStartingUp else {
            wpInfo("[Coordinator] startListening: already running/starting, skipping")
            return
        }
        isStartingUp = true
        defer { isStartingUp = false }
        wpInfo("[Coordinator] ▶ startListening")
        // Surface the "spinning up" state immediately so the user gets feedback on the
        // Play click. We hold .starting until the first audio frame arrives (in the
        // mixer-output consumer below) so the visible transition lines up with the
        // pipeline actually being live, not just with our setup code returning.
        overlayState.status = .starting
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

        // Transcription does NOT depend on the LLM — it runs locally. We deliberately
        // allow listening without a Gemini API key so users can use the app as a
        // standalone transcriber, or debug the audio pipeline independently of any AI
        // integration. AI features (detected-question triggers, auto-send, the composer)
        // noop until a key is present.
        wpInfo("[Coordinator] starting modules")
        let transcriber: TranscriptionProvider
        do {
            transcriber = try await makeStartedTranscriber()
        } catch {
            wpError("Transcriber start failed: \(error.localizedDescription)")
            overlayState.status = .error(error.localizedDescription)
            return
        }
        self.transcriber = transcriber

        if let key = settings.geminiAPIKey, !key.isEmpty {
            // refreshDerivedState already keeps aiProvider in sync; nothing to do here.
        } else {
            wpInfo("[Coordinator] no Gemini key — transcription-only mode")
            overlayState.appendSystemNote("ℹ️ Transcription is running. Add a Gemini API key in Settings to enable AI suggestions.", category: .general)
        }

        do {
            if processTapFrames == nil {
                try await systemCapture.start()
                wpInfo("[Coordinator] systemCapture.start OK (SCK)")
            }
            if settings.captureMicrophone {
                micCapture.preferredDeviceUID = settings.microphoneDeviceUID
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
        // Keep status as `.starting` here — the mixer-output consumer flips it to
        // `.listening` when the first audio frame arrives, so the UI's "ready" state
        // matches the moment audio is actually flowing rather than the moment our
        // setup returned. If audio never arrives, the 6-second watchdog surfaces a
        // warning so the user isn't left guessing.
        wpInfo("[Coordinator] ✓ Pipeline started, awaiting first audio frame")
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
                self.noFramesWarningID = self.overlayState.appendSystemNote("⚠️ \(message)", category: .transcript)
            } else if self.overlayState.transcriptCount == 0 {
                let message = "Audio is flowing (\(self.overlayState.audioFrameCount) frames) but no transcripts yet. Speak audibly or play a clearly-spoken video."
                wpWarn(message)
                self.noTranscriptsWarningID = self.overlayState.appendSystemNote("⚠️ \(message)", category: .transcript)
            }
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 14_000_000_000)
            guard let self, self.isRunning else { return }
            if self.overlayState.audioFrameCount > 0, self.overlayState.transcriptCount == 0 {
                let locale = self.settings.localeIdentifier
                let message = "Still no transcripts after 14 seconds (locale=\(locale)). Likely causes: (a) Speech Recognition not authorized — check System Settings → Privacy & Security → Speech Recognition; (b) wrong locale — open Settings → General → Locale and try \"en-US\"; (c) the audio is silent or non-speech. Open the 🐞 Diagnostics panel to see RMS values per buffer."
                wpWarn(message)
                self.noTranscriptsWarningID = self.overlayState.appendSystemNote("⚠️ \(message)", category: .transcript)
            }
        }
    }

    /// Dismiss the audio-not-flowing warning, if any. Called when the first frame arrives.
    private func dismissNoFramesWarning() {
        if let id = noFramesWarningID {
            overlayState.removeMessage(id: id)
            noFramesWarningID = nil
        }
    }

    /// Dismiss the no-transcripts warning, if any. Called when the first transcript arrives.
    private func dismissNoTranscriptsWarning() {
        if let id = noTranscriptsWarningID {
            overlayState.removeMessage(id: id)
            noTranscriptsWarningID = nil
        }
    }

    func stopListening() async {
        guard isRunning || transcriber != nil else { return }
        log.info("⏹ stopListening")
        for task in consumerTasks { task.cancel() }
        consumerTasks.removeAll()
        for task in pendingBoundaryTasks.values { task.cancel() }
        pendingBoundaryTasks.removeAll()
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

    /// Activate a session — either fresh or resumed. Always wipes the overlay's live
    /// transcript and chat first so switching sessions never leaks the previous session's
    /// content into the new one's UI. On resume we then rehydrate both lanes from the
    /// session's `transcript.md` / `chat.md` and hand the raw markdown to the AI context
    /// so the model sees prior history on its next prompt.
    func useSession(_ session: SessionMeta, resumed: Bool) async {
        // Re-selecting the current session shouldn't wipe its in-memory state — that
        // would discard the live transcript the user is actively building. Just keep
        // running with whatever is already loaded.
        if currentSession?.id == session.id { return }

        currentSession = session
        overlayState.transcript = []
        overlayState.clearChat()
        overlayState.transcriptCount = 0
        overlayState.audioFrameCount = 0
        await transcriptBuffer.clear()
        await context.reset()

        if resumed {
            let transcript = await SessionStore.shared.loadTranscriptMarkdown(session.id)
            let chat = await SessionStore.shared.loadChatMarkdown(session.id)
            let segments = await SessionStore.shared.loadTranscriptSegments(session.id)
            let messages = await SessionStore.shared.loadChatMessages(session.id)
            overlayState.transcript = segments
            overlayState.messages = messages
            await context.seedFromMarkdown(transcript: transcript, chat: chat)
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
                context: self.filteredSnapshot(snapshot),
                history: self.filteredHistory(history),
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

    // MARK: - Transcriber selection

    /// Constructs and starts a transcription provider. Prefers the macOS 26
    /// `SpeechAnalyzer` framework (no per-task ~60 s cap, no silence-timeout failure
    /// mode, native streaming) and falls back to the legacy `SFSpeechRecognizer`-based
    /// path on older systems — or if the modern path fails to start (e.g. locale model
    /// unavailable, asset install denied). Throws only when both paths fail.
    private func makeStartedTranscriber() async throws -> TranscriptionProvider {
        if #available(macOS 26.0, *) {
            let modern = SpeechAnalyzerTranscriber(locale: settings.locale)
            do {
                try await modern.start()
                wpInfo("[Coordinator] using SpeechAnalyzer (macOS 26+) transcriber")
                return modern
            } catch {
                wpWarn("[Coordinator] SpeechAnalyzer start failed (\(error.localizedDescription)); falling back to SFSpeechRecognizer")
                modern.stop()
            }
        }
        let legacy = AppleSpeechTranscriber(locale: settings.locale)
        try await legacy.start()
        wpInfo("[Coordinator] using SFSpeechRecognizer transcriber")
        return legacy
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

        let authStatus = SFSpeechRecognizer.authorizationStatus()
        wpInfo("Self-test: auth status = \(authStatus.rawValue) (\(authStatus))")
        switch authStatus {
        case .authorized: break
        case .notDetermined:
            let granted: Bool = await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
            }
            if !granted {
                overlayState.appendSystemNote("❌ Self-test failed: Speech Recognition permission was not granted.", category: .transcript)
                return
            }
        case .denied, .restricted:
            overlayState.appendSystemNote("❌ Self-test failed: Speech Recognition is denied or restricted. Enable it in System Settings → Privacy & Security → Speech Recognition.", category: .transcript)
            return
        @unknown default:
            overlayState.appendSystemNote("❌ Self-test failed: unknown authorization state.", category: .transcript)
            return
        }

        // Inspect what the recognizer actually offers for the chosen locale.
        if let probe = SFSpeechRecognizer(locale: settings.locale) {
            wpInfo("Self-test: recognizer for \(settings.localeIdentifier) — isAvailable=\(probe.isAvailable), supportsOnDeviceRecognition=\(probe.supportsOnDeviceRecognition)")
        } else {
            wpError("Self-test: SFSpeechRecognizer init returned nil for \(settings.localeIdentifier)")
        }

        let testTranscriber = AppleSpeechTranscriber(locale: settings.locale, autoRestart: false)
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

        // Snapshot the log buffer offset so we can find new errors that show up during this test.
        let preTestLogCount = LogBuffer.shared.entries.count

        // Synthesize and feed
        let synth = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: phrase)
        utterance.rate = 0.45
        utterance.voice = AVSpeechSynthesisVoice(language: settings.localeIdentifier)
            ?? AVSpeechSynthesisVoice(language: "en-US")

        let canonical = CanonicalAudioFormat.make()
        var buffersFed = 0
        var rmsAccum: Double = 0
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
                // Reset before each chunk — without this the converter latches into a
                // terminal "stream ended" state after the first endOfStream and yields
                // 0 frames forever after. Same fix as `MicrophoneCapture.handle`.
                converter.reset()
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
                    buffersFed += 1
                    rmsAccum += Double(Self.computeRMS(out))
                }
            }
        }
        let avgRMS = buffersFed > 0 ? rmsAccum / Double(buffersFed) : 0
        wpInfo("Self-test: fed \(buffersFed) buffers, avg RMS = \(String(format: "%.5f", avgRMS))")

        // Wait for the recognizer to flush.
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        collectorTask.cancel()
        testTranscriber.stop()

        let result = await collector.snapshot()
        wpInfo("Self-test result: \"\(result)\"")

        if !result.isEmpty {
            overlayState.appendSystemNote("✅ Self-test passed: recognizer produced \"\(result)\". The recognition pipeline works. If live transcription still fails, the bug is in audio capture / routing — your default output device isn't exposing audio to the macOS mixdown that we capture from.", category: .transcript)
            return
        }

        // Pull recognition errors that were logged during this run.
        let newEntries = Array(LogBuffer.shared.entries.dropFirst(preTestLogCount))
        let recognitionErrors = newEntries
            .filter { $0.level == .error && $0.message.contains("recognition error") }
            .map { $0.message }
        let errorTail = recognitionErrors.isEmpty ? "no recognizer errors logged" : "last error: \(recognitionErrors.last!)"

        overlayState.appendSystemNote("""
        ❌ Self-test failed: recognizer received \(buffersFed) synthesized buffers (avg RMS=\(String(format: "%.4f", avgRMS))) but produced no transcripts. \
        \(errorTail). \
        Common causes: Speech Recognition denied (System Settings → Privacy & Security → Speech Recognition), wrong locale (try en-US), or the locale's on-device model isn't installed.
        """, category: .transcript)
    }

    /// Mic Test — bypasses our pipeline entirely. Spins up an AVAudioEngine, taps the
    /// input, records 3 seconds, and reports the RMS. If RMS≈0 here, the microphone is
    /// genuinely delivering silent buffers (TCC denial / wrong device / muted input);
    /// if RMS is healthy, our pipeline is at fault.
    func runMicTest() async {
        overlayState.appendSystemNote("🎤 Mic test running for 3 seconds — speak now.", category: .transcript)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            let granted: Bool = await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
            }
            if !granted {
                overlayState.appendSystemNote("❌ Mic test failed: microphone permission was not granted.", category: .transcript)
                return
            }
        case .denied, .restricted:
            overlayState.appendSystemNote("❌ Mic test failed: microphone permission is denied. Enable Whisper Pilot under System Settings → Privacy & Security → Microphone.", category: .transcript)
            return
        @unknown default: return
        }

        if let info = MicrophoneCapture.defaultInputDeviceInfo() {
            wpInfo("Mic test: input device = \(info.name ?? "unknown") (id=\(info.id))")
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        wpInfo("Mic test: format \(format.sampleRate) Hz, \(format.channelCount) ch")

        let lock = NSLock()
        var sumSq: Double = 0
        var sampleCount: Int = 0
        var peakRMS: Float = 0

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            let channels = Int(buffer.format.channelCount)
            let frames = Int(buffer.frameLength)
            var localSum: Double = 0
            var localCount = 0
            for c in 0..<channels {
                let ptr = channelData[c]
                for i in 0..<frames {
                    let s = Double(ptr[i])
                    localSum += s * s
                    localCount += 1
                }
            }
            guard localCount > 0 else { return }
            let chunkRMS = Float((localSum / Double(localCount)).squareRoot())
            lock.lock()
            sumSq += localSum
            sampleCount += localCount
            if chunkRMS > peakRMS { peakRMS = chunkRMS }
            lock.unlock()
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            overlayState.appendSystemNote("❌ Mic test failed: engine.start threw \(error.localizedDescription)", category: .transcript)
            return
        }

        try? await Task.sleep(nanoseconds: 3_000_000_000)
        input.removeTap(onBus: 0)
        engine.stop()

        let avgRMS = sampleCount > 0 ? sqrt(sumSq / Double(sampleCount)) : 0
        let summary = "samples=\(sampleCount), avg RMS=\(String(format: "%.5f", avgRMS)), peak chunk RMS=\(String(format: "%.5f", peakRMS))"
        wpInfo("Mic test: \(summary)")

        if avgRMS < 0.001 {
            overlayState.appendSystemNote("❌ Mic test FAILED — silent audio. \(summary). Microphone is delivering empty buffers. Likely cause: wrong input device. Open System Settings → Sound → Input, pick the right microphone, raise Input Volume.", category: .transcript)
        } else if avgRMS < 0.005 {
            overlayState.appendSystemNote("⚠️ Mic test BARELY THERE — \(summary). Mic is capturing but very quietly. Speak louder, raise Input Volume in Sound settings, or move closer.", category: .transcript)
        } else {
            overlayState.appendSystemNote("✅ Mic test PASSED — mic is capturing real audio. \(summary). If transcription still fails, the recognizer (not capture) is the bug.", category: .transcript)
        }
    }

    /// System Audio Test — captures via Core Audio Process Tap for 3 seconds and reports
    /// RMS. If RMS≈0, the audio you hear isn't actually going through the macOS audio
    /// mixdown that taps and SCK both read from (typical with virtual / aggregate /
    /// some Bluetooth devices).
    func runSystemAudioTest() async {
        overlayState.appendSystemNote("🔊 System audio test running for 3 seconds — make sure audio is playing.", category: .transcript)
        if let out = MicrophoneCapture.defaultOutputDeviceInfo() {
            wpInfo("Audio test: output device = \(out.name ?? "unknown") (id=\(out.id))")
        }

        guard #available(macOS 14.4, *) else {
            overlayState.appendSystemNote("⚠️ System audio test requires macOS 14.4 or later (Process Tap). Falling back to ScreenCaptureKit isn't supported by this test.", category: .transcript)
            return
        }
        let pt = ProcessAudioCapture()
        do {
            try await pt.start()
        } catch {
            overlayState.appendSystemNote("❌ Audio test failed at start: \(error.localizedDescription)", category: .transcript)
            return
        }

        // OSAllocatedUnfairLock is the async-safe replacement for NSLock — Sendable, and
        // its `withLock` is statically rejected if the closure suspends. NSLock can't be
        // used from an async function under Swift 6 strict concurrency.
        let stats = OSAllocatedUnfairLock(initialState: RMSAccumulator())

        let frameTask = Task {
            for await frame in pt.frames {
                guard let channelData = frame.buffer.floatChannelData else { continue }
                let channels = Int(frame.buffer.format.channelCount)
                let frames = Int(frame.buffer.frameLength)
                var localSum: Double = 0
                var localCount = 0
                for c in 0..<channels {
                    let ptr = channelData[c]
                    for i in 0..<frames {
                        let s = Double(ptr[i])
                        localSum += s * s
                        localCount += 1
                    }
                }
                guard localCount > 0 else { continue }
                let chunkRMS = Float((localSum / Double(localCount)).squareRoot())
                // Re-bind to immutable lets so the @Sendable withLock closure captures
                // copies rather than var references (Swift 6 rejects var capture).
                let frameSum = localSum
                let frameCount = localCount
                stats.withLock { acc in
                    acc.sumSq += frameSum
                    acc.sampleCount += frameCount
                    if chunkRMS > acc.peakRMS { acc.peakRMS = chunkRMS }
                }
            }
        }

        try? await Task.sleep(nanoseconds: 3_000_000_000)
        frameTask.cancel()
        pt.stop()

        let snapshot = stats.withLock { $0 }
        let sumSq = snapshot.sumSq
        let sampleCount = snapshot.sampleCount
        let peakRMS = snapshot.peakRMS
        let avgRMS = sampleCount > 0 ? sqrt(sumSq / Double(sampleCount)) : 0
        let outName = MicrophoneCapture.defaultOutputDeviceInfo()?.name ?? "unknown"
        let summary = "samples=\(sampleCount), avg RMS=\(String(format: "%.5f", avgRMS)), peak chunk RMS=\(String(format: "%.5f", peakRMS)), default output=\"\(outName)\""
        wpInfo("Audio test: \(summary)")

        if avgRMS < 0.001 {
            overlayState.appendSystemNote("❌ System audio test FAILED — silent capture. \(summary). The audio you're hearing isn't reaching the macOS mixdown we capture from. Common causes: Bluetooth headphones using a codec that bypasses the mix, BlackHole/Loopback/aggregate device set as default output, or HDMI display audio. Switch the default output to built-in speakers or wired headphones via System Settings → Sound → Output.", category: .transcript)
        } else {
            overlayState.appendSystemNote("✅ System audio test PASSED — audio is reaching us. \(summary). If transcription still fails on real meeting audio, the recognizer is the bug.", category: .transcript)
        }
    }

    /// Accumulator for the diagnostic audio tests. Lives inside an `OSAllocatedUnfairLock`
    /// so the for-await loop body can update it without violating Swift 6 strict
    /// concurrency (NSLock can't be used from an async context).
    private struct RMSAccumulator {
        var sumSq: Double = 0
        var sampleCount: Int = 0
        var peakRMS: Float = 0
    }

    /// RMS over a Float32 PCM buffer; used for self-test diagnostics only.
    private static func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        let pointer = channelData.pointee
        var sum: Float = 0
        for i in 0..<frames { sum += pointer[i] * pointer[i] }
        return (sum / Float(frames)).squareRoot()
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
                        guard let self else { return }
                        self.overlayState.audioFrameCount = 1
                        self.dismissNoFramesWarning()
                        // First real audio frame — promote from the "starting" loading
                        // state to "listening". Guard against overwriting later states
                        // (thinking/streaming/error) in case something else changed
                        // status while we were spinning up.
                        if self.overlayState.status == .starting {
                            self.overlayState.status = .listening
                        }
                    }
                }
                if framesProcessed % 25 == 0 {
                    let count = framesProcessed
                    Task { @MainActor [weak self] in self?.overlayState.audioFrameCount = count }
                }
                // Per-channel mute gate. When muted, the captured frame is dropped before
                // VAD/transcription so the recognizer doesn't waste cycles on audio the
                // user has explicitly silenced.
                let isMuted: Bool
                if let strongSelf = self {
                    let channel = frame.channel
                    isMuted = await MainActor.run { [strongSelf] in
                        switch channel {
                        case .microphone: return strongSelf.overlayState.isMicrophoneMuted
                        case .system: return strongSelf.overlayState.isSystemAudioMuted
                        }
                    }
                } else {
                    isMuted = false
                }
                if isMuted { continue }
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
                // The display always shows every transcript line; only AI context
                // absorption is gated. With `includeSystemAudioInPrompt` off, the
                // user still sees what "Other" said but the model doesn't, which
                // is exactly the token-saving knob the user asked for.
                let absorbIntoAIContext: Bool
                if update.channel == .system {
                    absorbIntoAIContext = await MainActor.run { [weak self] in
                        self?.settings.includeSystemAudioInPrompt ?? true
                    }
                } else {
                    absorbIntoAIContext = true
                }
                if absorbIntoAIContext {
                    await context.absorb(update)
                }
                let snapshot = await buffer.snapshot()
                self?.overlayState.transcript = snapshot
                transcriptsSeen += 1
                self?.overlayState.transcriptCount = transcriptsSeen
                if transcriptsSeen == 1 {
                    wpInfo("First transcript update received")
                    self?.dismissNoTranscriptsWarning()
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
                if !self.settings.autoDetectQuestionsEnabled {
                    wpInfo("[Coordinator] trigger fired but auto-detect questions is disabled — skipping")
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
                    context: self.filteredSnapshot(snapshot),
                    history: self.filteredHistory(history),
                    question: trigger.text,
                    style: style
                )
                await self.runCompletion(prompt: prompt, ai: liveAI, origin: .detectedQuestion)
            }
        })
    }

    private func handleVADEvent(_ event: VoiceActivityEvent) async {
        await triggerEngine.absorb(event)

        // Optional debounced utterance-boundary cycling. Default is `.auto` — no
        // time-based cutting at all; we let SFSpeech finalize segments on its own.
        // Users can opt into pause-driven line breaks via Settings → General.
        if let delay = settings.utteranceBoundary.seconds {
            switch event {
            case .speechStarted(let channel, _):
                pendingBoundaryTasks[channel]?.cancel()
                pendingBoundaryTasks[channel] = nil
            case .speechEnded(let channel, _, _, _):
                pendingBoundaryTasks[channel]?.cancel()
                let task = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard !Task.isCancelled, let self else { return }
                    self.transcriber?.notifyVADBoundary(channel: channel)
                    self.pendingBoundaryTasks[channel] = nil
                }
                pendingBoundaryTasks[channel] = task
            }
        }

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
        // `autoSendEnabled` is the master switch (Settings → AI Behavior). When off
        // we never schedule the timer regardless of which interval the user picked,
        // so flipping it off mid-session immediately stops periodic summaries.
        guard isRunning,
              !overlayState.isAIPaused,
              settings.autoSendEnabled,
              let interval = settings.autoSendInterval.seconds else { return }
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
            let prompt = PromptBuilder.buildAutoSend(
                context: self.filteredSnapshot(snapshot),
                history: self.filteredHistory(history),
                style: self.settings.responseStyle
            )
            await self.runCompletion(prompt: prompt, ai: ai, origin: .autoSend)
        }
    }

    // MARK: - AI prompt filtering

    /// Applies the user's "include transcript in prompt" and "include chat history
    /// in prompt" toggles to the snapshot before it's handed to PromptBuilder.
    /// Live transcript lines, extracted topics, and resumed prior transcript
    /// markdown are gated on the transcript flag; resumed prior chat markdown is
    /// gated on the chat-history flag. `entities` is kept either way — it's a tiny
    /// derived list and useful for the model's continuity even when both sections
    /// are otherwise excluded.
    private func filteredSnapshot(_ snapshot: ConversationSnapshot) -> ConversationSnapshot {
        let includeT = settings.includeTranscriptInPrompt
        let includeH = settings.includeChatHistoryInPrompt
        return ConversationSnapshot(
            recentLines: includeT ? snapshot.recentLines : [],
            topics: includeT ? snapshot.topics : [],
            entities: snapshot.entities,
            priorTranscriptMarkdown: includeT ? snapshot.priorTranscriptMarkdown : nil,
            priorChatMarkdown: includeH ? snapshot.priorChatMarkdown : nil
        )
    }

    /// Drops the prior-turn chat history when the user has disabled it. Used by
    /// every PromptBuilder call so the toggle takes effect uniformly.
    private func filteredHistory(_ history: [ChatTurn]) -> [ChatTurn] {
        settings.includeChatHistoryInPrompt ? history : []
    }
}
