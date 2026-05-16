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
    /// App-wide context appended to every prompt regardless of session. Exposed for
    /// the Sessions home page to bind its `ContextDropdown` against. Persisted to
    /// `<App Support>/<bundle>/global-context.json` independently of any session.
    let globalContext = GlobalContextStore()

    private let log = Logger(subsystem: "com.whisperpilot.app", category: "Coordinator")

    /// Recreated at every `startListening`. `AudioMixer.output` is a single-use
    /// AsyncStream — once the previous session's consumer is cancelled, the same
    /// stream instance no longer reliably delivers frames to a new iterator. A
    /// fresh mixer (and therefore a fresh output stream) per session avoids the
    /// "loads forever, transcript never starts" symptom on the second session.
    private var audioMixer = AudioMixer()
    /// Recreated for the same reason as `audioMixer` — their `frames`
    /// `AsyncStream`s are single-iterator and the previous session's iteration
    /// (owned by the now-cancelled mixer consumer) leaves the stream in a state
    /// where the new mixer's iterator never receives the new buffers. Symptom
    /// was "first session transcribes fine, every subsequent session sits on a
    /// spinner / shows status .listening but produces no transcripts until the
    /// app is killed and relaunched."
    private var systemCapture = SystemAudioCapture()
    private var micCapture = MicrophoneCapture()
    /// When Core Audio Process Tap is in use, this stream is its output. The pipeline
    /// reads from whichever of `processTapFrames` or `systemCapture.frames` is active.
    private var processTapFrames: AsyncStream<AudioFrame>?
    private var processTapStop: (() -> Void)?
    private let vad = VoiceActivityDetector()
    private let transcriptBuffer = TranscriptBuffer()
    private let context = ConversationContext()
    /// Recreated at every `startListening`, same reasoning as `audioMixer` above:
    /// the events AsyncStream is single-use and a new pipeline needs a fresh one
    /// so trigger events from the new session aren't lost to a dead iterator.
    private var triggerEngine = TriggerEngine()

    private var transcriber: TranscriptionProvider?
    private var aiProvider: AIProvider?
    /// Model the active `aiProvider` was built with. Used to detect drift when the user
    /// changes the model in Settings (provider needs rebuilding) and to know what to
    /// migrate *away from* during a 404 auto-fallback.
    private var aiProviderModel: String?

    /// Fallback chain used when a model 404s mid-call (typically because Google retired
    /// it for new keys). We try the first entry that isn't the currently-failing model.
    /// Order is cheap-first so the auto-migration lands on the closest-equivalent option.
    private static let aiFallbackChain: [String] = [
        "gemini-2.5-flash",
        "gemini-2.0-flash-lite",
        "gemini-2.5-pro",
    ]

    private var consumerTasks: [Task<Void, Never>] = []
    /// Currently-streaming AI completions, keyed by the assistant message ID they
    /// render into. Tracked as a dictionary (not a single slot) because a follow-up
    /// detected question can arrive while the answer to the previous one is still
    /// streaming — and silently cancelling the in-flight reply produced the
    /// "responses cut mid-sentence" bug. Each completion finishes independently;
    /// `stopListening` cancels the whole set.
    private var inFlightCompletions: [UUID: Task<Void, Never>] = [:]
    /// IDs of currently-displayed watchdog warnings, so we can dismiss them when the
    /// underlying problem resolves itself (e.g. audio frames start flowing).
    private var noFramesWarningID: UUID?
    private var noTranscriptsWarningID: UUID?
    /// IDs of two startup notes shown while status is still `.starting`. Both get
    /// dismissed as soon as we leave `.starting` (either to `.listening` once a
    /// frame arrives, or to `.error` if something fails). Without these the user
    /// has no signal that a model download is in progress and they sit on a
    /// "loading forever" spinner on first launch.
    private var slowStartupNoteID: UUID?
    private var stuckStartupNoteID: UUID?
    /// ID of the "Transcription is running. Add a Gemini API key…" note. Tracking
    /// it lets us avoid appending a duplicate on a stop+start cycle within the
    /// same session, and dismiss it the moment a key is set.
    private var transcriptionOnlyNoteID: UUID?
    /// Per-channel scheduled "cycle the recognizer" tasks, used to debounce VAD boundary
    /// events. Mid-sentence pauses (~0.4 s) shouldn't split a transcript line — only
    /// genuine end-of-utterance pauses should. A pending task is cancelled when speech
    /// resumes within the debounce window.
    private var pendingBoundaryTasks: [AudioChannel: Task<Void, Never>] = [:]
    private var settingsObserver: AnyCancellable?
    private var pausedObserver: AnyCancellable?
    /// Subscribes to `overlayState.$sessionContext` and schedules a debounced save.
    /// Manual debouncing rather than Combine's `.debounce` because the latter reads
    /// `currentSession?.id` at fire time, which lets a fast session switch route
    /// session A's pending save into session B's file. This sink instead captures
    /// the session ID synchronously per-emission via `scheduleContextSave`.
    private var sessionContextSaver: AnyCancellable?
    /// In-flight debounced save for the session context. Holding the session ID
    /// alongside the value means switching sessions can flush this to the correct
    /// file (the *old* one) before swapping `currentSession`.
    private var pendingContextSave: (id: SessionID, value: SessionContext, work: DispatchWorkItem)?
    /// Set during `openSession` so the just-loaded context value doesn't immediately
    /// schedule a write back (it would be a no-op, but avoids triggering touches).
    private var isLoadingSessionContext: Bool = false

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
            aiProviderModel = settings.geminiModel
        }

        settingsObserver = settings.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.refreshDerivedState() }
        }

        pausedObserver = overlayState.$isAIPaused
            .removeDuplicates()
            .sink { _ in
                // The toggle button itself is the visual indicator — no system note needed.
            }

        sessionContextSaver = overlayState.$sessionContext
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] (context: SessionContext) in
                self?.scheduleContextSave(context)
            }
    }

    /// Debounces saves of the session context to disk so typing bursts don't
    /// generate per-keystroke writes. Crucially, the target session ID is captured
    /// here at scheduling time, not at fire time — without that, a session switch
    /// during the debounce window would write the wrong session's content into the
    /// new session's `context.json`.
    private func scheduleContextSave(_ value: SessionContext) {
        if isLoadingSessionContext { return }
        guard let id = currentSession?.id else { return }

        if let pending = pendingContextSave {
            if pending.id == id {
                // Same session — just re-arm the timer with the latest value.
                pending.work.cancel()
            } else {
                // Different session somehow already has a pending save (race with
                // useSession). Flush it to its *captured* session before scheduling
                // the new one, so we never lose content or cross-write files.
                pending.work.cancel()
                let toSave = pending.value
                let oldID = pending.id
                Task { await SessionStore.shared.saveContext(toSave, to: oldID) }
            }
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self, let pending = self.pendingContextSave else { return }
            let toSave = pending.value
            let targetID = pending.id
            self.pendingContextSave = nil
            Task { await SessionStore.shared.saveContext(toSave, to: targetID) }
        }
        pendingContextSave = (id: id, value: value, work: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Cancels any pending debounced save and writes its value to the session it
    /// was *captured for* — synchronously awaiting the save before returning so a
    /// caller about to swap `currentSession` knows the old session's content is
    /// safely on disk first.
    private func flushPendingContextSave() async {
        guard let pending = pendingContextSave else { return }
        pending.work.cancel()
        pendingContextSave = nil
        await SessionStore.shared.saveContext(pending.value, to: pending.id)
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
        // The session context flush already happens inside `stopListening`. Global
        // context lives outside of any session, so make sure its in-flight debounce
        // is drained too — otherwise the last edit in the Sessions home page can
        // vanish when the app terminates mid-debounce.
        await globalContext.flush()
    }

    private func refreshDerivedState() {
        // Sync the live `aiProvider` reference with the current API key. Runs whether or
        // not we're actively listening — composer prompts work independently.
        let key = settings.geminiAPIKey ?? ""
        if !key.isEmpty {
            // Rebuild the provider when either the key changes (provider absent) or the
            // user picks a different model in Settings. Without the model check, switching
            // models in Settings had no effect until the next app launch.
            if aiProvider == nil || aiProviderModel != settings.geminiModel {
                aiProvider = GeminiProvider(apiKey: key, model: settings.geminiModel)
                aiProviderModel = settings.geminiModel
            }
            // A key was set while the transcription-only note is on screen — dismiss
            // it now, otherwise it lingers as misleading "Add a Gemini API key" copy.
            dismissTranscriptionOnlyNote()
        } else if aiProvider != nil {
            aiProvider = nil
            aiProviderModel = nil
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
        // Fresh AsyncStream instances per session — see the property declarations
        // for why. Doing this here (rather than at `stopListening` time) keeps the
        // instances valid for any UI / debug code that reads them between sessions.
        audioMixer = AudioMixer()
        triggerEngine = TriggerEngine()
        systemCapture = SystemAudioCapture()
        micCapture = MicrophoneCapture()
        // VAD holds per-channel `isSpeaking` state; if the previous session ended
        // mid-utterance, that state lingers and the next session's first frames are
        // mis-classified (no `.speechStarted` until silence is detected first).
        await vad.reset()
        // Surface the "spinning up" state immediately so the user gets feedback on the
        // Play click. We hold .starting until the first audio frame arrives (in the
        // mixer-output consumer below) so the visible transition lines up with the
        // pipeline actually being live, not just with our setup code returning.
        overlayState.status = .starting
        // Kick off the startup watchdog BEFORE any awaits — `makeStartedTranscriber()`
        // can block for tens of seconds on first launch while macOS downloads the
        // on-device speech model, and the normal no-frames watchdog doesn't start
        // until after `isRunning = true`. Without this the user sits on an opaque
        // "Starting…" spinner with no signal at all.
        startStartupWatchdog()
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
            dismissStartupNotes()
            return
        }
        self.transcriber = transcriber

        if let key = settings.geminiAPIKey, !key.isEmpty {
            // Key present — make sure no stale "transcription-only" note is hanging
            // around from an earlier run in this session.
            dismissTranscriptionOnlyNote()
        } else if transcriptionOnlyNoteID == nil {
            // Append exactly once per session. Without this guard, a stop+start cycle
            // (or returning to the same session via the back button) would stack a
            // second identical note on top of the first.
            wpInfo("[Coordinator] no Gemini key — transcription-only mode")
            transcriptionOnlyNoteID = overlayState.appendSystemNote(
                "ℹ️ Transcription is running. Add a Gemini API key in Settings to enable AI suggestions.",
                category: .general
            )
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
            dismissStartupNotes()
            return
        }

        startPipeline(transcriber: transcriber, ai: aiProvider)

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
                let micHint = self.settings.captureMicrophone
                    ? "Microphone capture is on — speak audibly into the mic, or play system audio through your default output device (“\(outName)”)."
                    : "Microphone capture is off. Either enable Capture Microphone in Settings → Capture so your voice is transcribed, or play system audio through your default output device (“\(outName)”)."
                let message = "No audio frames after 6 seconds. \(method) is set up but isn't receiving any audio. \(micHint) Virtual / aggregate / Bluetooth output devices sometimes bypass the macOS audio mixdown that we capture from."
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

    /// Dismiss the "transcription is running, add a Gemini key" note. Called when a
    /// key gets set (via Settings) or when a fresh session starts.
    private func dismissTranscriptionOnlyNote() {
        if let id = transcriptionOnlyNoteID {
            overlayState.removeMessage(id: id)
            transcriptionOnlyNoteID = nil
        }
    }

    /// Dismiss the slow / stuck startup notes once startup actually progresses
    /// (status leaves `.starting`). Called from the mixer-output consumer's
    /// first-frame branch and from any startup-failure path.
    private func dismissStartupNotes() {
        if let id = slowStartupNoteID {
            overlayState.removeMessage(id: id)
            slowStartupNoteID = nil
        }
        if let id = stuckStartupNoteID {
            overlayState.removeMessage(id: id)
            stuckStartupNoteID = nil
        }
    }

    /// Watchdog for the "first run on a fresh install" hang. The existing
    /// `startNoFramesWatchdog` only runs after `isRunning = true`, which means it
    /// never fires when `makeStartedTranscriber()` is the thing blocking — and
    /// that's exactly when first-launch model downloads on macOS 26 (SpeechAnalyzer)
    /// can take 30s–2min. Without this, the user just stares at a "Starting…"
    /// spinner with no clue what's happening.
    ///
    /// Fires only while `status == .starting`, so it auto-cancels itself once
    /// startup completes (or fails).
    private func startStartupWatchdog() {
        // ~8s: gentle nudge — "this is taking a while, here's probably why".
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self else { return }
            guard self.overlayState.status == .starting else { return }
            let message = "Startup is taking longer than usual. On a fresh install macOS may be downloading on-device speech recognition models in the background — this can take 30 seconds to a few minutes. Hang tight."
            wpInfo(message)
            self.slowStartupNoteID = self.overlayState.appendSystemNote("ℹ️ \(message)", category: .general)
        }

        // ~30s: louder warning with actionable diagnostics. By this point either the
        // model download is genuinely slow (slow network) or something more serious
        // is blocking (permission prompt dismissed, recognizer unavailable for the
        // chosen locale, etc.).
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self else { return }
            guard self.overlayState.status == .starting else { return }
            let locale = self.settings.localeIdentifier
            // Only suggest an alternate locale when the current one isn't already
            // en-US — telling the user "try en-US" while they're *on* en-US is
            // exactly the kind of useless hint that wastes their time during a
            // real bug hunt.
            let localeHint = locale.lowercased().hasPrefix("en-us")
                ? "the chosen locale (\(locale)) might not have a working on-device model on this Mac — try another locale (e.g. en-GB) in Settings → General → Locale"
                : "the chosen locale (\(locale)) might not be supported on this Mac — try \"en-US\" in Settings → General → Locale"
            let micHint = self.settings.captureMicrophone
                ? "no audio is reaching the recognizer — speak into your mic, or play system audio through your default output device"
                : "Capture Microphone is off and no system audio is playing — enable mic capture in Settings → Capture, or start playing audio"
            let message = "Still starting after 30 seconds. Possible causes: (a) \(micHint); (b) the on-device speech model is downloading on a slow connection — wait a bit longer; (c) Speech Recognition permission was denied — check System Settings → Privacy & Security → Speech Recognition; (d) \(localeHint). Click ⏹ to abort."
            wpWarn(message)
            self.stuckStartupNoteID = self.overlayState.appendSystemNote("⚠️ \(message)", category: .general)
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
        for task in inFlightCompletions.values { task.cancel() }
        inFlightCompletions.removeAll()
        // Persist any in-flight context edit before tearing the session down so the
        // last few keystrokes of the user's notes don't disappear on stop.
        await flushPendingContextSave()

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
        // Tear down any startup notes still floating from a stuck startup that the
        // user just bailed out of with Stop.
        dismissStartupNotes()
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

        // Flush any debounced session-context save BEFORE swapping `currentSession`.
        // Without this, a fast switch from A→B after typing in A would either lose
        // A's edit (if the debounce gets reset by the load-emission for B) or
        // worse, write A's content into B's file. The flush captures the *old*
        // session's ID from the pending save record itself.
        await flushPendingContextSave()

        currentSession = session
        overlayState.transcript = []
        overlayState.clearChat()
        // `clearChat()` wipes the messages array but our tracked note IDs are
        // separate state — nil them out so the next `startListening` doesn't see
        // a stale ID and skip its (now legitimately needed) re-append.
        transcriptionOnlyNoteID = nil
        noFramesWarningID = nil
        noTranscriptsWarningID = nil
        slowStartupNoteID = nil
        stuckStartupNoteID = nil
        overlayState.transcriptCount = 0
        overlayState.audioFrameCount = 0
        await transcriptBuffer.clear()
        await context.reset()

        // Hydrate the session-level context (user notes + attached files) from disk.
        // `isLoadingSessionContext` suppresses the debounced saver so the load itself
        // doesn't trigger a write back. Always set the published value, even when the
        // loaded context is empty, so the dropdown reflects the new session cleanly.
        let loadedContext = await SessionStore.shared.loadContext(session.id)
        isLoadingSessionContext = true
        overlayState.sessionContext = loadedContext
        isLoadingSessionContext = false

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

    /// "Help AI" button: the user thinks there's an unanswered question in the recent
    /// transcript that the auto-detector missed. We don't pre-extract the question
    /// (the heuristic is what failed in the first place); instead we hand the model
    /// the same context block a user prompt would get and instruct it to find the
    /// question on its own. Honored even when AI is paused — it's an explicit manual
    /// invocation, like the composer.
    func requestHelpAI() {
        guard let ai = aiProvider else {
            overlayState.appendSystemNote("⚠️ Add a Gemini API key in Settings to use the AI.", category: .ai)
            return
        }
        overlayState.appendAutoTriggerPreamble(
            origin: .helpAI,
            text: "Scanning recent transcript for a question…"
        )
        overlayState.status = .thinking
        wpInfo("[Coordinator] Help AI requested")
        let history = chatHistorySnapshot(excludingLast: false)
        Task { [weak self] in
            guard let self else { return }
            let snapshot = await self.context.snapshotWithPrior()
            let prompt = PromptBuilder.buildHelpAI(
                context: self.filteredSnapshot(snapshot),
                history: self.filteredHistory(history),
                style: self.settings.responseStyle
            )
            await self.runCompletion(prompt: prompt, ai: ai, origin: .helpAI)
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
        // Tell the transcriber only about channels we'll actually feed. Without
        // the mic flag, an unused mic pipe still spins up its own recognizer task
        // that fires "No speech detected" after a silent timeout — pure noise in
        // the user's log and a misleading signal during debugging.
        var channels: Set<AudioChannel> = [.system]
        if settings.captureMicrophone { channels.insert(.microphone) }

        if #available(macOS 26.0, *) {
            let modern = SpeechAnalyzerTranscriber(locale: settings.locale)
            do {
                try await modern.start(enabledChannels: channels)
                wpInfo("[Coordinator] using SpeechAnalyzer (macOS 26+) transcriber (channels=\(channels))")
                return modern
            } catch {
                wpWarn("[Coordinator] SpeechAnalyzer start failed (\(error.localizedDescription)); falling back to SFSpeechRecognizer")
                modern.stop()
            }
        }
        let legacy = AppleSpeechTranscriber(locale: settings.locale)
        try await legacy.start(enabledChannels: channels)
        wpInfo("[Coordinator] using SFSpeechRecognizer transcriber (channels=\(channels))")
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
            // Self-test only synthesizes mic-channel audio, so don't bother
            // spinning up the system-channel recognizer pipe.
            try await testTranscriber.start(enabledChannels: [.microphone])
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
                        // Dismiss the "this is taking a while" startup notes —
                        // the pipeline is clearly alive now.
                        self.dismissStartupNotes()
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
                // Feed every system-channel partial straight to the trigger engine so
                // `pendingCandidate` is kept fresh as the recognizer hypothesizes. By
                // the time VAD reports speech-end, the latest text is already scored
                // and ready to fire — no waiting for finalization, which is what made
                // detected questions arrive 30s late.
                if update.channel == .system {
                    let liveSegment = TranscriptSegment(
                        id: update.id,
                        text: update.text,
                        isFinal: update.isFinal,
                        channel: update.channel,
                        startedAt: update.timestamp,
                        updatedAt: update.timestamp
                    )
                    await engine.consider(segment: liveSegment)
                }
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
                // Surface the detected question as a user-style bubble in the AI pane so
                // the user can see *what* the detector picked up — without this, a fired
                // trigger only shows up as an unlabeled assistant reply, and a failed call
                // shows up as nothing at all.
                self.overlayState.appendAutoTriggerPreamble(origin: .detectedQuestion, text: trigger.text)
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

        // Hand the most recent segment on the system channel to the trigger engine
        // regardless of finalization state — `.auto` SFSpeech mode can delay
        // finalization by tens of seconds, and we want the trigger to fire on the
        // post-utterance VAD pause, not on the eventual finalize.
        if let last = await transcriptBuffer.lastSegment(on: .system) {
            await triggerEngine.consider(segment: last)
        }
    }

    private func runCompletion(prompt: Prompt, ai: AIProvider, origin: ChatMessage.Origin, hasAttemptedFallback: Bool = false) async {
        // Reserve the assistant bubble + register the task BEFORE starting the stream
        // so concurrent completions each have their own slot in `inFlightCompletions`
        // and their own message ID. Multiple completions can stream in parallel —
        // this is intentional: a follow-up detected question shouldn't cut off the
        // previous answer.
        let messageId = overlayState.beginAssistantStream(origin: origin)
        overlayState.status = .streaming
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                var deltaCount = 0
                // If the provider never sends a `.finish(reason)`, the stream
                // ended without a clean terminal event — treat that as an unknown
                // / dropped-connection finish so the user gets a diagnostic note
                // instead of a silently-truncated bubble.
                var finishReason: AIFinishReason = .other(nil)
                for try await event in ai.streamCompletion(prompt: prompt) {
                    if Task.isCancelled { break }
                    switch event {
                    case .delta(let text):
                        deltaCount += 1
                        self.overlayState.appendDelta(to: messageId, text)
                    case .finish(let reason):
                        finishReason = reason
                    }
                }
                self.log.info("Stream complete (\(deltaCount) deltas, reason=\(String(describing: finishReason), privacy: .public))")
                self.overlayState.finishAssistant(id: messageId)
                if let diagnostic = finishReason.diagnosticMessage {
                    // Non-clean finishes are loud failures the user needs to know
                    // about — otherwise a MAX_TOKENS cut looks like a model that
                    // just stopped mid-thought for no reason.
                    self.overlayState.appendSystemNote("⚠️ AI reply was incomplete — \(diagnostic).", category: .ai)
                    wpWarn("AI stream finished with non-stop reason: \(diagnostic)")
                }
                if let finalText = self.overlayState.messages.first(where: { $0.id == messageId })?.text,
                   !finalText.isEmpty {
                    self.persistChatTurn(role: "Assistant", text: finalText)
                }
            } catch is CancellationError {
                self.overlayState.finishAssistant(id: messageId)
            } catch {
                // 404 means the selected model isn't reachable on this key — almost always
                // because Google retired it for new users (e.g. `gemini-2.0-flash`). Try
                // the next entry in the fallback chain once before surfacing the error.
                if !hasAttemptedFallback,
                   case let GeminiError.http(status, _) = error,
                   status == 404,
                   let (fromModel, newAI) = self.migrateToFallbackModel() {
                    self.overlayState.finishAssistant(id: messageId)
                    let note = "ℹ️ Model \(fromModel) is unavailable on your API key. Auto-switched to \(self.settings.geminiModel) and retrying."
                    self.overlayState.appendSystemNote(note, category: .ai)
                    wpInfo("AI model fallback: \(fromModel) → \(self.settings.geminiModel)")
                    // Drop this task from the in-flight map BEFORE recursing — the
                    // recursive call registers its own new entry, and we don't want
                    // the outer cleanup-on-exit below to fire twice for one logical
                    // request.
                    self.inFlightCompletions[messageId] = nil
                    await self.runCompletion(prompt: prompt, ai: newAI, origin: origin, hasAttemptedFallback: true)
                    return
                }
                let message = error.localizedDescription
                wpError("AI stream failed: \(message)")
                self.overlayState.finishAssistant(id: messageId)
                self.overlayState.appendSystemNote("⚠️ \(message)", category: .ai)
            }
            self.completionFinished(messageId: messageId)
        }
        inFlightCompletions[messageId] = task
        await task.value
    }

    /// Called by every non-fallback exit path of `runCompletion`. Removes the task
    /// from the in-flight map and, only when nothing else is still streaming, flips
    /// the status pill back to `.listening` (or `.idle` if we've been stopped in
    /// the meantime). With concurrent completions, we can't just unconditionally
    /// flip after each one — that would prematurely declare "done" while another
    /// stream is still arriving.
    private func completionFinished(messageId: UUID) {
        inFlightCompletions[messageId] = nil
        guard inFlightCompletions.isEmpty else { return }
        switch overlayState.status {
        case .streaming, .thinking, .error:
            overlayState.status = isRunning ? .listening : .idle
        default:
            break
        }
    }

    /// Picks the next model from `aiFallbackChain` that isn't the currently-failing one,
    /// updates `settings.geminiModel` (so Settings UI reflects the migration and the
    /// choice persists), and rebuilds `aiProvider`. Returns `(oldModel, newProvider)` or
    /// `nil` if no API key is configured.
    private func migrateToFallbackModel() -> (String, AIProvider)? {
        guard let key = settings.geminiAPIKey, !key.isEmpty else { return nil }
        let current = settings.geminiModel
        guard let next = Self.aiFallbackChain.first(where: { $0 != current }) else { return nil }
        settings.geminiModel = next
        let provider = GeminiProvider(apiKey: key, model: next)
        aiProvider = provider
        aiProviderModel = next
        return (current, provider)
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
        // The session context block (user notes + attached files) isn't gated by any
        // toggle — it's an explicit choice the user made to attach this material, so
        // they presumably want it in every prompt until they remove it.
        var enriched = snapshot
        enriched.sessionContextBlock = overlayState.sessionContext.promptBlock
        enriched.globalContextBlock = globalContext.context.promptBlock
        return ConversationSnapshot(
            recentLines: includeT ? enriched.recentLines : [],
            topics: includeT ? enriched.topics : [],
            entities: enriched.entities,
            priorTranscriptMarkdown: includeT ? snapshot.priorTranscriptMarkdown : nil,
            priorChatMarkdown: includeH ? snapshot.priorChatMarkdown : nil,
            sessionContextBlock: enriched.sessionContextBlock,
            globalContextBlock: enriched.globalContextBlock
        )
    }

    /// Drops the prior-turn chat history when the user has disabled it. Used by
    /// every PromptBuilder call so the toggle takes effect uniformly.
    private func filteredHistory(_ history: [ChatTurn]) -> [ChatTurn] {
        settings.includeChatHistoryInPrompt ? history : []
    }
}
