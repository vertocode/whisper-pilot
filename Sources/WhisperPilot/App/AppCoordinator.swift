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
    /// Per-channel pending transcript line waiting to be written to
    /// `transcript.md`. Each finalized transcript update with a matching
    /// segment id updates the entry in place; only when the next final
    /// arrives with a *different* id (= a new utterance) do we flush the
    /// previous one to disk. This is how we avoid the "same sentence
    /// appears as N growing lines in transcript.md" bug — the pre-prompt
    /// synthetic-final flush can emit isFinal=true repeatedly for one
    /// utterance, and without this de-duplication every emission would
    /// append a new (truncated) line to the file. The UI's TranscriptBuffer
    /// and ConversationContext both already dedupe by id; this brings disk
    /// persistence in line with that semantic.
    private var pendingTranscriptLineByChannel: [AudioChannel: (id: UUID, text: String, timestamp: Date)] = [:]
    /// The most recent line each channel actually wrote to `transcript.md`.
    /// Lets `queueTranscriptPersistence` drop a late re-final of an utterance
    /// that already hit the disk (same id, or containment-duplicate text within
    /// the merge window) instead of appending it as a duplicate line.
    private var lastPersistedLineByChannel: [AudioChannel: (id: UUID, text: String, timestamp: Date)] = [:]
    /// Currently-streaming AI completions, keyed by the assistant message ID they
    /// render into. Tracked as a dictionary (not a single slot) because a follow-up
    /// detected question can arrive while the answer to the previous one is still
    /// streaming — and silently cancelling the in-flight reply produced the
    /// "responses cut mid-sentence" bug. Each completion finishes independently;
    /// `stopListening` cancels the whole set.
    private var inFlightCompletions: [UUID: Task<Void, Never>] = [:]

    /// Performance safety valve. The sampler reads this process's CPU / memory /
    /// thermal state; the governor turns a stream of those readings into a
    /// `.ok / .tier1Pause / .tier2Stop` decision. Both run only while listening —
    /// `startResourceMonitor` polls at ~1.3 Hz and feeds each sample (with a
    /// monotonic timestamp) into the governor.
    /// Rebuilt at each session start from the user's Settings thresholds (see
    /// `startResourceMonitor`), so threshold edits take effect on the next listen.
    private var resourceGovernor = ResourceGovernor()
    private var resourceSampler: ResourceSampling = ResourceSampler()
    private var resourceMonitorTask: Task<Void, Never>?
    /// True once Tier-1 has engaged for the current high-load episode. Tier-1
    /// re-emits `.tier1Pause` on every sample while load stays high; this latch
    /// makes the side effects (pause AI, cancel completions, post the alert) fire
    /// once per episode and reset when load recovers.
    private var tier1Engaged = false
    /// ID of the Tier-1 "AI paused" inline alert, so it can be dismissed when load
    /// recovers or the session stops.
    private var tier1NoteID: UUID?
    /// True once Tier-2 has fired for the current session. `.tier2Stop` re-emits on
    /// every sample while the governor is in its terminal tier; this latch makes the
    /// async hard-stop kick off exactly once.
    private var tier2Engaged = false
    /// True when the valve (not the user) paused AI auto-suggestions, so recovery may
    /// auto-resume them. Cleared the moment the user toggles AI themselves during the
    /// episode — we never override an explicit user choice.
    private var tier1PausedAI = false
    /// Set while the valve itself is flipping `isAIPaused`, so the paused observer can
    /// distinguish valve-initiated changes from explicit user toggles.
    private var valveTogglingAI = false

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
    /// Per-channel mute flags mirrored off the main actor. The mixer-output
    /// consumer is a detached task that checks mute state once per audio frame;
    /// reading the `@Published` flags directly would force a `MainActor.run` hop
    /// per frame. Instead these Combine sinks push every toggle change into a
    /// lock-protected cache the consumer reads synchronously with no actor hop.
    private let muteFlags = OSAllocatedUnfairLock(initialState: MuteFlags())
    private var micMuteObserver: AnyCancellable?
    private var systemMuteObserver: AnyCancellable?

    /// Plain value mirror of the overlay's two mute toggles, read by the audio
    /// pipeline consumer without touching the main actor.
    private struct MuteFlags: Sendable {
        var micMuted = false
        var systemMuted = false
    }
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
        // Wire up the AI provider eagerly if the active model's vendor has a
        // key, so the composer works before/without ever clicking ▶ Play. AI
        // prompts are independent of listening.
        if let provider = makeProviderForActiveModel() {
            aiProvider = provider
            aiProviderModel = settings.activeModel
        }

        settingsObserver = settings.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.refreshDerivedState() }
        }

        pausedObserver = overlayState.$isAIPaused
            .removeDuplicates()
            .sink { [weak self] _ in
                // The toggle button itself is the visual indicator — no system note needed.
                // A change the valve didn't make is an explicit user choice, so stop
                // tracking it for auto-resume: recovery must never fight the user.
                guard let self, !self.valveTogglingAI else { return }
                self.tier1PausedAI = false
            }

        sessionContextSaver = overlayState.$sessionContext
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] (context: SessionContext) in
                self?.scheduleContextSave(context)
            }

        // Mirror the mute toggles into the off-main-actor cache so the per-frame
        // pipeline consumer never has to hop to the main actor to check them. The
        // `@Published` projected publisher delivers the newly-set value, so the
        // cache stays in sync the instant a toggle flips.
        micMuteObserver = overlayState.$isMicrophoneMuted
            .removeDuplicates()
            .sink { [weak self] muted in
                self?.muteFlags.withLock { $0.micMuted = muted }
            }
        systemMuteObserver = overlayState.$isSystemAudioMuted
            .removeDuplicates()
            .sink { [weak self] muted in
                self?.muteFlags.withLock { $0.systemMuted = muted }
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
        // Sync the live `aiProvider` reference with the current active model
        // and whichever key its vendor needs. Runs whether or not we're
        // actively listening — composer prompts work independently.
        let provider = makeProviderForActiveModel()
        if let provider {
            // Rebuild on either: provider absent (key just added), or active
            // model changed (user picked a different one in Settings / the
            // overlay). Without the model check, switching mid-session had
            // no effect until the next app launch.
            if aiProvider == nil || aiProviderModel != settings.activeModel {
                aiProvider = provider
                aiProviderModel = settings.activeModel
            }
            // A key was set while the transcription-only note is on screen — dismiss
            // it now, otherwise it lingers as misleading "Add an API key" copy.
            dismissTranscriptionOnlyNote()
        } else if aiProvider != nil {
            aiProvider = nil
            aiProviderModel = nil
            overlayState.appendSystemNote("ℹ️ AI key for the selected model was removed. Transcription still running; AI features disabled until a key is added.", category: .general)
        }

        if !isRunning {
            switch overlayState.status {
            case .needsAPIKey:
                if provider != nil { overlayState.status = .idle }
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
        // The `forceScreenCaptureKitForSystemAudio` flag is auto-managed by the
        // silent-tap watchdog for Macs (some Mac mini configurations) where
        // ProcessTap creates without error but silently delivers zero frames —
        // once set, the SCK path is used instead, which triggers the Screen
        // Recording permission prompt and reliably captures audio there.
        if #available(macOS 14.4, *), !settings.forceScreenCaptureKitForSystemAudio {
            let pt = ProcessAudioCapture()
            do {
                try await pt.start()
                processTapFrames = pt.frames
                processTapStop = { pt.stop() }
                wpInfo("[Coordinator] ✓ Using Core Audio Process Tap (audio-only, no screen recording)")
            } catch {
                wpWarn("Process Tap unavailable (\(error.localizedDescription)); falling back to ScreenCaptureKit")
            }
        } else if settings.forceScreenCaptureKitForSystemAudio {
            wpInfo("[Coordinator] ProcessTap skipped (forceScreenCaptureKitForSystemAudio = true — set by the silent-tap watchdog on a previous session)")
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

        // Apply the "always transcribe my mic" default for this session. When off, the
        // mic channel starts muted (frames dropped before VAD/transcription) so the mic
        // recognizer doesn't run by default; system audio still transcribes. The user can
        // flip it on any time with the in-session mic toggle. Set before the pipeline so
        // the mute mirror is in place before the first frame is processed.
        overlayState.isMicrophoneMuted = !settings.alwaysTranscribeMic

        startPipeline(transcriber: transcriber, ai: aiProvider)

        isRunning = true
        // Keep status as `.starting` here — the mixer-output consumer flips it to
        // `.listening` when the first audio frame arrives, so the UI's "ready" state
        // matches the moment audio is actually flowing rather than the moment our
        // setup returned. If audio never arrives, the 6-second watchdog surfaces a
        // warning so the user isn't left guessing.
        wpInfo("[Coordinator] ✓ Pipeline started, awaiting first audio frame")
        startNoFramesWatchdog()
        startResourceMonitor()
    }

    // MARK: - Performance safety valve

    /// Begins polling the resource sampler while listening. Runs at ~1.3 Hz and
    /// only for the lifetime of the session — torn down in `stopListening`, so an
    /// idle app never samples. Each reading is stamped with a monotonic elapsed
    /// time (the governor needs a non-decreasing clock for its sustain windows)
    /// and fed to the governor; the returned decision is mapped to an action.
    private func startResourceMonitor() {
        resourceMonitorTask?.cancel()
        // Rebuild the governor from the current Settings thresholds so user edits
        // (CPU% / memory cap) apply to this session. `.reset()` is implied by the
        // fresh instance, but we keep it explicit for the per-episode latches below.
        resourceGovernor = ResourceGovernor(config: settings.resourceGovernorConfig)
        resourceGovernor.reset()
        tier1Engaged = false
        tier2Engaged = false
        tier1PausedAI = false
        resourceMonitorTask = Task { @MainActor [weak self] in
            let start = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(750))
                guard let self, self.isRunning, !Task.isCancelled else { return }
                // Sampler and governor are accessed through `self` (MainActor) so
                // the non-Sendable governor is never captured by this @Sendable task.
                let sample = self.resourceSampler.sample()
                // Publish for the live Diagnostics readout on every tick — independent
                // of the valve, so the numbers update even when the valve is disabled.
                self.overlayState.resourceSample = sample
                // Valve disabled in Settings: sample for the readout only, never trip
                // the governor (reverts to the old no-limit behavior).
                guard self.settings.safetyValveEnabled else { continue }
                let elapsed = start.duration(to: .now)
                let seconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) * 1e-18
                self.handleResourceDecision(self.resourceGovernor.evaluate(sample, at: seconds))
            }
        }
    }

    /// Stops the resource monitor and clears the valve's per-session state. Called
    /// from `stopListening` so the next session starts with a clean governor.
    private func stopResourceMonitor() {
        resourceMonitorTask?.cancel()
        resourceMonitorTask = nil
        resourceGovernor.reset()
        // Clear the live readout — the monitor only samples while listening, so an
        // idle session shows "—" rather than a stale last reading.
        overlayState.resourceSample = nil
        if tier1Engaged {
            dismissTier1Note()
            tier1Engaged = false
        }
        // If the valve (not the user) paused AI, lift that pause on teardown so a
        // resumed session never starts silently throttled by a stale valve decision.
        if tier1PausedAI && overlayState.isAIPaused {
            valveTogglingAI = true
            overlayState.isAIPaused = false
            valveTogglingAI = false
        }
        tier1PausedAI = false
    }

    private func handleResourceDecision(_ decision: ResourceDecision) {
        switch decision {
        case .ok:
            // Load recovered after Tier-1: clear the latch and its alert so a later
            // episode can re-engage, then resume auto-suggestions if the valve was
            // the one that paused them — restoring auto-detection without a session
            // restart. If the user toggled AI themselves during the episode,
            // `tier1PausedAI` is already false, so we leave their choice alone.
            if tier1Engaged {
                dismissTier1Note()
                tier1Engaged = false
                if tier1PausedAI && overlayState.isAIPaused {
                    valveTogglingAI = true
                    overlayState.isAIPaused = false
                    valveTogglingAI = false
                    overlayState.appendSystemNote(
                        "✅ System load back to normal — AI auto-suggestions resumed.",
                        category: .ai
                    )
                }
                tier1PausedAI = false
            }
        case .tier1Pause:
            engageTier1()
        case .tier2Stop:
            engageTier2()
        }
    }

    /// Tier-1 soft brake: pause AI auto-detection, cancel any in-flight AI
    /// completions, and surface an inline alert with a one-tap mic-shed button.
    /// Core transcription is deliberately untouched — only auxiliary AI work backs
    /// off. Explicit user AI actions (composer, Help AI, Summary, Action Items)
    /// keep working because they don't consult `isAIPaused`.
    private func engageTier1() {
        guard !tier1Engaged else { return }
        tier1Engaged = true
        wpWarn("[Coordinator] Tier-1 safety valve engaged — high sustained load; pausing AI auto-suggestions")
        // Pause auto-detect / auto-send. The trigger-events consumer checks this.
        // Only mark the pause as valve-owned (eligible for auto-resume on recovery)
        // when we actually flip it — if the user had already paused AI, that's their
        // choice and recovery must not silently resume it. `valveTogglingAI` brackets
        // the assignment so the paused observer reads it as valve-initiated.
        if !overlayState.isAIPaused {
            valveTogglingAI = true
            overlayState.isAIPaused = true
            valveTogglingAI = false
            tier1PausedAI = true
        }
        // Cancel streaming AI replies to free their CPU immediately. Transcription
        // (a separate consumer task) keeps running.
        for task in inFlightCompletions.values { task.cancel() }
        inFlightCompletions.removeAll()
        tier1NoteID = overlayState.appendSystemNote(
            "⚠️ High system load — AI auto-suggestions paused to keep transcription smooth. Manual prompts (composer, Help AI, Summary, Action items) still work. Resume auto-suggestions any time with the AI toggle.",
            category: .ai,
            actionLabel: "Disable my mic for this session",
            actionKind: .shedMicrophoneForSession
        )
    }

    private func dismissTier1Note() {
        if let id = tier1NoteID {
            overlayState.removeMessage(id: id)
            tier1NoteID = nil
        }
    }

    /// Tier-2 hard stop: sustained overload after Tier-1, or thermal pressure
    /// (`.serious`/`.critical`). Posts a clear alert, then routes through the normal
    /// `stopListening` teardown so capture, recognizers, and the monitor shut down
    /// exactly as a manual Stop would — dropping CPU to near-idle. The transcript and
    /// chat survive (stop preserves them), so the user can resume with ▶ when load
    /// eases. Latched so the repeated `.tier2Stop` decisions only trigger one stop.
    private func engageTier2() {
        guard !tier2Engaged else { return }
        tier2Engaged = true
        wpWarn("[Coordinator] Tier-2 safety valve engaged — sustained overload or thermal pressure; stopping listening")
        // Post the alert BEFORE teardown. `stopListening` preserves the transcript and
        // chat messages (it only zeroes counters and drops startup notes), so this note
        // remains visible after the stop to explain why listening ended.
        overlayState.appendSystemNote(
            "🛑 System under heavy load — listening stopped automatically to keep your Mac responsive. Your transcript and session are saved; press ▶ to resume when load eases.",
            category: .ai
        )
        // stopListening is async; hop off this synchronous decision handler. It tears
        // down the monitor (cancelling the polling task) as part of normal teardown.
        Task { @MainActor [weak self] in
            await self?.stopListening()
        }
    }

    /// Mutes the microphone channel for the running session in response to the
    /// Tier-1 alert's button. Reuses the existing per-channel mute (frames are
    /// dropped before VAD/transcription, so the mic recognizer stops being fed)
    /// rather than persisting a setting — the choice is scoped to this session and
    /// reversible via the mic toggle.
    func shedMicrophoneForSession() {
        guard !overlayState.isMicrophoneMuted else { return }
        overlayState.isMicrophoneMuted = true
        overlayState.appendSystemNote(
            "ℹ️ Microphone muted for this session to reduce load. Re-enable it any time with the mic toggle.",
            category: .ai
        )
    }

    /// Surfaces visible warnings when the audio or transcription pipeline is silent. Two
    /// staged checks: 6 seconds for "is audio flowing at all", then 14 seconds to confirm
    /// transcripts started. The 14s gate fires only if audio is flowing — that's the case
    /// where SFSpeechRecognizer is the bottleneck and the user needs a concrete next step.
    private func startNoFramesWatchdog() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, self.isRunning else { return }
            let sysCount = self.overlayState.systemAudioFrameCount
            let micCount = self.overlayState.microphoneFrameCount
            let outName = MicrophoneCapture.defaultOutputDeviceInfo()?.name ?? "unknown"
            let method = self.processTapFrames != nil ? "Core Audio Process Tap" : "ScreenCaptureKit"
            if self.overlayState.audioFrameCount == 0 {
                let micHint = self.settings.captureMicrophone
                    ? "Microphone capture is on — speak audibly into the mic, or play system audio through your default output device (“\(outName)”)."
                    : "Microphone capture is off. Either enable Capture Microphone in Settings → Capture so your voice is transcribed, or play system audio through your default output device (“\(outName)”)."
                let message = "No audio frames after 6 seconds. \(method) is set up but isn't receiving any audio. \(micHint) Virtual / aggregate / Bluetooth output devices sometimes bypass the macOS audio mixdown that we capture from."
                wpWarn(message)
                self.noFramesWarningID = self.overlayState.appendSystemNote("⚠️ \(message)", category: .transcript)
            } else if sysCount == 0 && micCount > 0 {
                // Mic is delivering, system is not. Classic ProcessTap / output-device
                // routing problem — the audio you're playing isn't going through the
                // mixdown we tap into. Tell the user exactly what's happening so they
                // don't waste time wondering whether it's a transcription bug.
                let message = "Microphone is delivering audio (\(micCount) frames) but no system audio frames have arrived via \(method). Your audio is likely playing through an output device (“\(outName)”) whose route bypasses the macOS audio mixdown — typical for Bluetooth headsets, virtual / aggregate devices, and some external DACs. Try switching your output to the built-in speakers temporarily, or play audio through a different app, to confirm."
                wpWarn(message)
                self.noFramesWarningID = self.overlayState.appendSystemNote("⚠️ \(message)", category: .transcript)
            } else if sysCount > 0 && micCount == 0 && self.settings.captureMicrophone {
                // The reverse: system audio works but mic doesn't, even though
                // capture mic is enabled. Most likely a permission or device
                // selection problem.
                let message = "System audio is being captured (\(sysCount) frames) but no microphone frames have arrived. Check System Settings → Privacy & Security → Microphone, and confirm the input device in Settings → Devices points at the mic you're using."
                wpWarn(message)
                self.noFramesWarningID = self.overlayState.appendSystemNote("⚠️ \(message)", category: .transcript)
            } else if self.overlayState.transcriptCount == 0 {
                let message = "Audio is flowing (sys=\(sysCount), mic=\(micCount) frames) but no transcripts yet. Speak audibly or play a clearly-spoken video."
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

            // Specific case: system audio frames are flowing but produce no
            // transcripts, while mic transcripts work fine — the classic
            // "ProcessTap reads an empty mixdown" scenario on Macs where the
            // output device (USB / Bluetooth / aggregate) bypasses the global
            // audio mixdown. The audio in the captured buffer is bit-for-bit
            // zero, so no amount of gain helps. Switching to ScreenCaptureKit
            // uses a different capture mechanism and reliably works in this
            // setup. When Screen Recording permission is already granted we
            // make the switch automatically (persisted, so future sessions
            // start on the working path); otherwise switching would fire the
            // macOS permission prompt, so we ask first via a one-click note.
            let sysFrames = self.overlayState.systemAudioFrameCount
            let sysTranscripts = self.overlayState.systemTranscriptCount
            let micTranscripts = self.overlayState.microphoneTranscriptCount
            let usingProcessTap = (self.processTapFrames != nil)
            let forceSCKAlreadyOn = self.settings.forceScreenCaptureKitForSystemAudio
            if usingProcessTap,
               !forceSCKAlreadyOn,
               sysFrames > 100,
               sysTranscripts == 0,
               micTranscripts > 0 {
                let message = "System audio frames are arriving (sys=\(sysFrames)) but contain silence — the macOS audio mixdown that Core Audio Process Tap reads from looks empty. This usually happens when the Mac's output device (USB headset, Bluetooth headphones, aggregate / virtual driver) routes audio in a way that bypasses the mixdown. ScreenCaptureKit uses a different capture path that works around it."
                wpWarn(message)
                if self.permissions.snapshot.screenRecording == .granted {
                    self.settings.forceScreenCaptureKitForSystemAudio = true
                    self.overlayState.appendSystemNote(
                        "🔧 System audio wasn't reaching the transcriber via the default capture path — switched to ScreenCaptureKit automatically and restarting the session. This choice is remembered.",
                        category: .transcript
                    )
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        // If the user hit Stop in the gap since the watchdog
                        // fired, honor it — don't resurrect a stopped session.
                        guard self.isRunning else { return }
                        await self.stopListening()
                        await self.startListening()
                    }
                } else {
                    self.overlayState.appendSystemNote(
                        "⚠️ \(message) Switching needs macOS Screen Recording permission (audio only — no video is recorded).",
                        category: .transcript,
                        actionLabel: "Switch capture path & retry",
                        actionKind: .enableForceSCKAndRestart
                    )
                }
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
        // Stop the safety-valve monitor and clear its per-session state so an idle
        // app never polls and the next session starts with a clean governor.
        stopResourceMonitor()
        // Persist any in-flight context edit before tearing the session down so the
        // last few keystrokes of the user's notes don't disappear on stop.
        await flushPendingContextSave()
        // Same idea for transcript.md: the deferred-write scheme only flushes a
        // pending utterance when the *next* segment arrives, so the very last
        // utterance of the session needs an explicit flush here or it would
        // never make it to disk.
        await flushPendingTranscriptLines()

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
        overlayState.systemAudioFrameCount = 0
        overlayState.microphoneFrameCount = 0
        overlayState.systemTranscriptCount = 0
        overlayState.microphoneTranscriptCount = 0
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
        // Same reason for the pending transcript line: flush it to the *old*
        // session's transcript.md before we change `currentSession`, otherwise
        // the in-flight utterance would land in the new session's file.
        await flushPendingTranscriptLines()
        // The just-persisted dedup memory belongs to the old session's file.
        lastPersistedLineByChannel.removeAll()

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
        // The Tier-1 alert lives in the chat that `clearChat()` just wiped; drop
        // the stale ID and latch so the valve can re-alert cleanly in the new session.
        tier1NoteID = nil
        tier1Engaged = false
        tier2Engaged = false
        tier1PausedAI = false
        overlayState.transcriptCount = 0
        overlayState.audioFrameCount = 0
        overlayState.systemAudioFrameCount = 0
        overlayState.microphoneFrameCount = 0
        overlayState.systemTranscriptCount = 0
        overlayState.microphoneTranscriptCount = 0
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

        // Apply the session's stored model selection. On resume we honor the
        // value saved when the session was last used; on a brand-new session
        // we lock the current global default in so the session is reproducible
        // across resumes even if the user changes the default later.
        if let storedID = session.selectedModel,
           AIModelRegistry.model(for: storedID) != nil {
            if settings.activeModel != storedID {
                settings.activeModel = storedID
            }
        } else {
            // Persist the current global default onto the session so future
            // resumes are stable. Doing this in `useSession` keeps the write
            // co-located with all other session-hydration side effects.
            await SessionStore.shared.setSelectedModel(settings.activeModel, for: session.id)
            currentSession?.selectedModel = settings.activeModel
        }
    }

    /// Called by the overlay's in-session model picker. Updates the global
    /// active model (so the next provider rebuild uses it) and persists the
    /// choice onto the current session so resuming later brings it back.
    /// No-op when the model id isn't in the registry — defends against a
    /// stale stored id surviving a future model-name change.
    func selectModel(_ modelID: String) {
        guard let model = AIModelRegistry.model(for: modelID) else { return }
        let previous = settings.activeModel
        let changed = previous != modelID
        if changed {
            settings.activeModel = modelID
        }
        if let id = currentSession?.id {
            Task { await SessionStore.shared.setSelectedModel(modelID, for: id) }
            currentSession?.selectedModel = modelID
        }
        // Brief confirmation so the user knows the click took effect — the
        // chip color flip alone is easy to miss when the menu closes. Only
        // post on actual change; re-picking the same model is a no-op and
        // shouldn't clutter the AI lane.
        guard changed else { return }
        let previousName = AIModelRegistry.model(for: previous)?.displayName ?? previous
        let nextName = model.displayName
        overlayState.appendSystemNote(
            "🔀 Switched AI model: \(previousName) → \(nextName).",
            category: .ai
        )
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
            await self.absorbPendingTranscripts()
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
            await self.absorbPendingTranscripts()
            let snapshot = await self.context.snapshotWithPrior()
            let prompt = PromptBuilder.buildHelpAI(
                context: self.filteredSnapshot(snapshot),
                history: self.filteredHistory(history),
                style: self.settings.responseStyle
            )
            await self.runCompletion(prompt: prompt, ai: ai, origin: .helpAI)
        }
    }

    /// "Summary" button — recap the meeting from the live transcript + AI chat.
    /// Same plumbing as Help AI: flush pending transcripts so the snapshot is
    /// current, then call the model with the dedicated summary prompt.
    func requestSummary() {
        guard let ai = aiProvider else {
            overlayState.appendSystemNote("⚠️ Add a Gemini API key in Settings to use the AI.", category: .ai)
            return
        }
        overlayState.appendAutoTriggerPreamble(
            origin: .summary,
            text: "Summarizing the meeting so far…"
        )
        overlayState.status = .thinking
        wpInfo("[Coordinator] Summary requested")
        let history = chatHistorySnapshot(excludingLast: false)
        Task { [weak self] in
            guard let self else { return }
            await self.absorbPendingTranscripts()
            let snapshot = await self.context.snapshotWithPrior()
            let prompt = PromptBuilder.buildSummary(
                context: self.filteredSnapshot(snapshot),
                history: self.filteredHistory(history)
            )
            await self.runCompletion(prompt: prompt, ai: ai, origin: .summary)
        }
    }

    /// "Action items" button — pull explicit commitments / asks out of the
    /// transcript. The prompt instructs the model to say "no action items
    /// found" verbatim if nothing qualifies, so the user always gets a
    /// definitive answer instead of a hedged "maybe…" reply.
    func requestActionItems() {
        guard let ai = aiProvider else {
            overlayState.appendSystemNote("⚠️ Add a Gemini API key in Settings to use the AI.", category: .ai)
            return
        }
        overlayState.appendAutoTriggerPreamble(
            origin: .actionItems,
            text: "Extracting action items from the transcript…"
        )
        overlayState.status = .thinking
        wpInfo("[Coordinator] Action items requested")
        let history = chatHistorySnapshot(excludingLast: false)
        Task { [weak self] in
            guard let self else { return }
            await self.absorbPendingTranscripts()
            let snapshot = await self.context.snapshotWithPrior()
            let prompt = PromptBuilder.buildActionItems(
                context: self.filteredSnapshot(snapshot),
                history: self.filteredHistory(history)
            )
            await self.runCompletion(prompt: prompt, ai: ai, origin: .actionItems)
        }
    }

    /// "Answer what's on screen" global shortcut (⌘⇧A by default). Captures the
    /// current display, attaches it to a dedicated prompt, and asks the AI to
    /// answer whatever question is visible — multiple-choice or free text — or to
    /// say there's no question and offer to help. Honored even when AI is paused
    /// and even when no listening session is running: it's an explicit, manual
    /// invocation that's independent of the audio pipeline. Requires Screen
    /// Recording permission (same as the composer's "See my screen").
    func answerScreen() {
        guard let ai = aiProvider else {
            overlayState.appendSystemNote("⚠️ Add an API key in Settings to use the AI.", category: .ai)
            return
        }
        overlayState.appendAutoTriggerPreamble(
            origin: .answerScreen,
            text: "Reading your screen…"
        )
        overlayState.status = .thinking
        wpInfo("[Coordinator] Answer-screen requested")
        let history = chatHistorySnapshot(excludingLast: false)
        Task { [weak self] in
            guard let self else { return }
            await self.absorbPendingTranscripts()
            let snapshot = await self.context.snapshotWithPrior()
            var prompt = PromptBuilder.buildAnswerScreen(
                context: self.filteredSnapshot(snapshot),
                history: self.filteredHistory(history),
                style: self.settings.responseStyle
            )
            guard let imageData = await self.captureScreenJPEG() else {
                self.overlayState.appendSystemNote("⚠️ Couldn't capture your screen. Grant Screen Recording permission in System Settings → Privacy & Security → Screen Recording, then try again.", category: .ai)
                // Nothing to answer without the screen — drop back out of the
                // thinking state so the pill doesn't hang.
                if self.overlayState.status == .thinking {
                    self.overlayState.status = self.isRunning ? .listening : .idle
                }
                return
            }
            prompt.imageJPEGBase64 = imageData.base64EncodedString()
            wpInfo("Answer-screen screenshot captured (\(imageData.count) bytes)")
            await self.runCompletion(prompt: prompt, ai: ai, origin: .answerScreen)
        }
    }

    /// Resolves which `CGDirectDisplayID` screen capture should target. A non-zero
    /// `screenCaptureDisplayID` pins capture to that specific monitor regardless of
    /// where the user is looking; `0` means "follow the monitor the pointer is on".
    private func resolvedCaptureDisplayID() -> CGDirectDisplayID {
        let configured = settings.screenCaptureDisplayID
        if configured != 0 { return configured }
        return ScreenEnumerator.currentPointerDisplayID()
    }

    /// Captures the configured display via ScreenCaptureKit, downsamples to ≤1280 px wide so
    /// we don't ship 4K frames to the model, and JPEG-encodes at quality 0.7. Returns nil
    /// if Screen Recording permission isn't granted or no display is shareable.
    private func captureScreenJPEG(maxWidth: Int = 1280, quality: CGFloat = 0.7) async -> Data? {
        do {
            let content = try await SCShareableContent.current
            guard !content.displays.isEmpty else { return nil }
            // On a multi-monitor setup, pick the display the user configured (a
            // specific monitor) or, when set to follow, the one the pointer is on.
            // If the configured monitor was disconnected, fall back to the first
            // available display so capture still produces *something*.
            let targetID = resolvedCaptureDisplayID()
            let display = content.displays.first(where: { $0.displayID == targetID })
                ?? content.displays.first!
            if settings.screenCaptureDisplayID != 0, display.displayID != settings.screenCaptureDisplayID {
                wpWarn("Screen capture: configured monitor (id=\(settings.screenCaptureDisplayID)) not connected — using display id=\(display.displayID) instead")
            }
            // Exclude Whisper Pilot's own windows (chiefly the floating overlay) from
            // the capture. Otherwise the overlay — which we bring to front to show the
            // answer when the ⌘⇧A shortcut fires — would occlude the very question the
            // user wants read, and the composer's "See my screen" would ship a picture
            // of our own UI sitting on top of the user's content.
            let ownBundleID = Bundle.main.bundleIdentifier
            let excluded = content.applications.filter { $0.bundleIdentifier == ownBundleID }
            let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
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

    /// Constructs and starts a transcription provider, best engine first:
    ///
    /// 1. **Parakeet Unified 0.6B** (FluidAudio, CoreML on the Neural Engine) for
    ///    English locales — 1.79% WER on LibriSpeech test-clean with punctuation,
    ///    the same accuracy class as Meet/Teams server captions. Falls through if
    ///    the one-time ~600 MB model download or the CoreML load fails.
    /// 2. **`SpeechAnalyzer`** (macOS 26+) — Apple's long-form engine; supports
    ///    every locale Apple ships a model for.
    /// 3. **`SFSpeechRecognizer`** legacy path on older systems.
    ///
    /// Throws only when every applicable path fails.
    private func makeStartedTranscriber() async throws -> TranscriptionProvider {
        // Tell the transcriber only about channels we'll actually feed. Without
        // the mic flag, an unused mic pipe still spins up its own recognizer task
        // that fires "No speech detected" after a silent timeout — pure noise in
        // the user's log and a misleading signal during debugging.
        var channels: Set<AudioChannel> = [.system]
        if settings.captureMicrophone { channels.insert(.microphone) }

        // Parakeet is English-only; other locales go straight to the Apple engines.
        if settings.localeIdentifier.lowercased().hasPrefix("en") {
            let parakeet = ParakeetTranscriber(statusNote: { [weak self] note in
                Task { @MainActor [weak self] in
                    self?.overlayState.appendSystemNote(note, category: .general)
                }
            })
            do {
                try await parakeet.start(enabledChannels: channels)
                wpInfo("[Coordinator] using Parakeet Unified (FluidAudio) transcriber (channels=\(channels))")
                return parakeet
            } catch {
                wpWarn("[Coordinator] Parakeet start failed (\(error.localizedDescription)); falling back to Apple speech engines")
                parakeet.stop()
            }
        } else {
            wpInfo("[Coordinator] locale \(settings.localeIdentifier) is not English — using Apple speech engines")
        }

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

        // Snapshot the mute-flag cache once; the lock is Sendable so the detached
        // consumer can read it per frame without hopping to the main actor.
        let muteFlags = self.muteFlags
        consumerTasks.append(Task.detached { [weak self] in
            // Counters accumulate locally and flush to `OverlayState` on a ~2 Hz
            // throttle. Previously each frame spawned a `Task { @MainActor }` to
            // bump per-channel counts and a `MainActor.run` to read mute state —
            // a main-actor hop per audio frame, the dominant standing CPU cost of
            // the live pipeline. Now we touch the main actor at most ~twice a
            // second regardless of frame rate.
            var framesProcessed = 0
            var systemFrames = 0
            var micFrames = 0
            var lastCounterPublish: ContinuousClock.Instant = .now
            for await frame in mixer.output {
                framesProcessed += 1
                switch frame.channel {
                case .system: systemFrames += 1
                case .microphone: micFrames += 1
                }
                if framesProcessed == 1 {
                    wpInfo("Pipeline: first audio frame received (channel=\(frame.channel))")
                    let firstSys = systemFrames
                    let firstMic = micFrames
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.overlayState.audioFrameCount = 1
                        self.overlayState.systemAudioFrameCount = firstSys
                        self.overlayState.microphoneFrameCount = firstMic
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
                    lastCounterPublish = .now
                } else {
                    // Flush the absolute counters at ~2 Hz so the watchdog still sees
                    // which side is silent and the Diagnostics frame counts still move.
                    let now = ContinuousClock.now
                    if now - lastCounterPublish >= .milliseconds(500) {
                        lastCounterPublish = now
                        let total = framesProcessed
                        let sys = systemFrames
                        let mic = micFrames
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.overlayState.audioFrameCount = total
                            self.overlayState.systemAudioFrameCount = sys
                            self.overlayState.microphoneFrameCount = mic
                        }
                    }
                }
                // Per-channel mute gate. When muted, the captured frame is dropped before
                // VAD/transcription so the recognizer doesn't waste cycles on audio the
                // user has explicitly silenced. Reads the cached flags — no actor hop.
                let isMuted = muteFlags.withLock { flags in
                    switch frame.channel {
                    case .microphone: return flags.micMuted
                    case .system: return flags.systemMuted
                    }
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
            var lastTranscriptUIPublish: ContinuousClock.Instant = .now
            // Per-channel throttle for live question scoring. Feeding the trigger
            // engine on every partial re-scores the same growing hypothesis dozens
            // of times a second; debouncing to ~0.5 s of new speech (while still
            // always scoring finalized segments) keeps detection latency under half
            // a second without the per-partial CPU churn.
            var lastQuestionConsider: [AudioChannel: ContinuousClock.Instant] = [:]
            for await update in transcriber.transcripts {
                await buffer.apply(update)
                // Feed every system-channel partial straight to the trigger engine so
                // `pendingCandidate` is kept fresh as the recognizer hypothesizes. By
                // the time VAD reports speech-end, the latest text is already scored
                // and ready to fire — no waiting for finalization, which is what made
                // detected questions arrive 30s late.
                // Forward both channels to the trigger engine if their per-channel
                // toggle is on. Engine state is per-channel, so concurrent
                // candidates on Other and Me can coexist without clobbering.
                let autoDetectChannel = await MainActor.run { [weak self] in
                    self?.shouldAutoDetectQuestion(on: update.channel) ?? false
                }
                if autoDetectChannel {
                    // Always score finalized segments; for partials, only every
                    // ~0.5 s per channel so a fast-growing hypothesis doesn't
                    // re-trigger scoring on every recognizer callback.
                    let now = ContinuousClock.now
                    let last = lastQuestionConsider[update.channel]
                    let dueByTime = last.map { now - $0 >= .milliseconds(500) } ?? true
                    if update.isFinal || dueByTime {
                        lastQuestionConsider[update.channel] = now
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
                // Republish the live transcript at ~3–4 Hz (was 10 Hz). Finals still
                // publish immediately so a completed line never waits on the timer.
                let now = ContinuousClock.now
                if update.isFinal || now - lastTranscriptUIPublish >= .milliseconds(250) {
                    let snapshot = await buffer.snapshot()
                    self?.overlayState.transcript = snapshot
                    lastTranscriptUIPublish = now
                }
                transcriptsSeen += 1
                self?.overlayState.transcriptCount = transcriptsSeen
                if transcriptsSeen == 1 {
                    wpInfo("First transcript update received")
                    self?.dismissNoTranscriptsWarning()
                }
                // Per-channel finalized-transcript counters. The watchdog uses
                // these to tell apart "ProcessTap is delivering silent buffers
                // → no system transcripts" from "user just hasn't spoken yet
                // → no mic transcripts" — they have very different remedies.
                if update.isFinal {
                    let channel = update.channel
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        switch channel {
                        case .system: self.overlayState.systemTranscriptCount += 1
                        case .microphone: self.overlayState.microphoneTranscriptCount += 1
                        }
                    }
                }

                // Persist finalized transcript lines to the active session's
                // transcript.md — but DEFER the actual append. Each finalized
                // update with the same segment id replaces the in-memory
                // "pending" entry for its channel; only when the next final
                // arrives with a different id (= a new utterance) do we flush
                // the previous one to disk. `stopListening` flushes anything
                // still pending. This dedupes the file in the face of the
                // pre-prompt synthetic-final flush, which legitimately emits
                // isFinal=true multiple times for one utterance as the
                // recognizer's hypothesis grows.
                if update.isFinal,
                   !update.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    let updateCopy = update
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.queueTranscriptPersistence(updateCopy)
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
                // Defense-in-depth: re-check the per-channel toggle here in case
                // the user disabled the relevant side after the engine queued
                // this candidate. Without this, a setting change wouldn't take
                // effect until the next cooldown window.
                if !self.shouldAutoDetectQuestion(on: trigger.channel) {
                    wpInfo("[Coordinator] trigger fired on \(trigger.channel) but auto-detect for that channel is disabled — skipping")
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
                await self.absorbPendingTranscripts()
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

    /// Debounce between a VAD speech-end event and the utterance-boundary
    /// notification. Combined with the VAD's own 0.4 s hangover, a ~1.5 s pause
    /// starts a new transcript line — the split cadence Meet/Teams captions use.
    /// Short mid-sentence pauses cancel the pending boundary when speech resumes.
    /// Only the legacy SFSpeech engine acts on the notification (it cycles its
    /// recognition task at the boundary, which is also the restart point that
    /// avoids its ~1-minute task limit); SpeechAnalyzer segments on its own and
    /// ignores it.
    private static let utteranceBoundaryDebounceSeconds: TimeInterval = 1.1

    private func handleVADEvent(_ event: VoiceActivityEvent) async {
        await triggerEngine.absorb(event)

        switch event {
        case .speechStarted(let channel, _):
            pendingBoundaryTasks[channel]?.cancel()
            pendingBoundaryTasks[channel] = nil
        case .speechEnded(let channel, _, _, _):
            pendingBoundaryTasks[channel]?.cancel()
            let delay = Self.utteranceBoundaryDebounceSeconds
            let task = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.transcriber?.notifyVADBoundary(channel: channel)
                self.pendingBoundaryTasks[channel] = nil
            }
            pendingBoundaryTasks[channel] = task
        }

        // Hand the most recent segment on the VAD event's channel to the trigger
        // engine regardless of finalization state — `.auto` SFSpeech mode can
        // delay finalization by tens of seconds, and we want the trigger to
        // fire on the post-utterance VAD pause, not on the eventual finalize.
        // Gated on the per-channel auto-detect toggle so we don't waste cycles
        // scoring segments on a channel the user has disabled.
        let vadChannel = vadChannelFor(event)
        if shouldAutoDetectQuestion(on: vadChannel),
           let last = await transcriptBuffer.lastSegment(on: vadChannel) {
            await triggerEngine.consider(segment: last)
        }
    }

    /// Channel selector used by `handleVADEvent` to forward the right utterance
    /// to the trigger engine. Both VAD event variants carry a channel; this
    /// just unwraps it.
    private nonisolated func vadChannelFor(_ event: VoiceActivityEvent) -> AudioChannel {
        switch event {
        case .speechStarted(let channel, _): return channel
        case .speechEnded(let channel, _, _, _): return channel
        }
    }

    /// Centralized lookup so the trigger gating logic stays in one place. Used
    /// at the source (before calling `engine.consider`) and at the sink (before
    /// firing the AI), so a settings flip mid-conversation takes effect on the
    /// next event in either direction.
    private func shouldAutoDetectQuestion(on channel: AudioChannel) -> Bool {
        switch channel {
        case .system: return settings.autoDetectQuestionsFromOther
        case .microphone: return settings.autoDetectQuestionsFromMe
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
                    let note = "ℹ️ Model \(fromModel) is unavailable on your API key. Auto-switched to \(self.settings.activeModel) and retrying."
                    self.overlayState.appendSystemNote(note, category: .ai)
                    wpInfo("AI model fallback: \(fromModel) → \(self.settings.activeModel)")
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

    /// Build an `AIProvider` for whatever `settings.activeModel` resolves to,
    /// using the right API key for the model's vendor. Returns `nil` if the
    /// vendor's key isn't configured — callers treat that as "AI disabled".
    ///
    /// Centralized so every place that needs to spin up a provider (init,
    /// `refreshDerivedState`, the fallback retry) goes through the same
    /// vendor-aware path. Without this, adding Claude would mean N if/elses
    /// scattered across the coordinator.
    private func makeProviderForActiveModel() -> AIProvider? {
        let modelID = settings.activeModel
        guard let model = AIModelRegistry.model(for: modelID) else { return nil }
        switch model.vendor {
        case .gemini:
            guard let key = settings.geminiAPIKey, !key.isEmpty else { return nil }
            return GeminiProvider(apiKey: key, model: modelID)
        case .anthropic:
            guard let key = settings.anthropicAPIKey, !key.isEmpty else { return nil }
            return AnthropicProvider(apiKey: key, model: modelID)
        }
    }

    /// Picks the next Gemini model from `aiFallbackChain` that isn't the
    /// currently-failing one, updates `settings.activeModel` (so the UI
    /// reflects the migration and the choice persists), and rebuilds
    /// `aiProvider`. Returns `(oldModel, newProvider)` or `nil` if no Gemini
    /// API key is configured.
    ///
    /// Scoped to Gemini because Anthropic doesn't have the same
    /// silently-retired-models problem — a 404 from Claude almost always
    /// means a bad model id rather than a billing-tier difference, and
    /// flipping Sonnet→Opus behind the user's back would silently change
    /// the cost model.
    private func migrateToFallbackModel() -> (String, AIProvider)? {
        guard let key = settings.geminiAPIKey, !key.isEmpty else { return nil }
        let current = settings.activeModel
        // Only Gemini models participate in the fallback chain.
        guard AIModelRegistry.model(for: current)?.vendor == .gemini else { return nil }
        guard let next = Self.aiFallbackChain.first(where: { $0 != current }) else { return nil }
        settings.activeModel = next
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
    /// Enqueue a finalized transcript update for persistence to `transcript.md`.
    /// Same-segment updates (same `update.id`) replace the pending entry in
    /// place; a new segment id flushes the previous one to disk before
    /// tracking the new one. Net effect: one line in transcript.md per
    /// utterance, with the latest (most complete) text.
    private func queueTranscriptPersistence(_ update: TranscriptUpdate) async {
        let channel = update.channel
        // A late re-final of a line that already went to disk (the next
        // utterance pushed it out before the recognizer's own final landed)
        // can't be merged into the file — drop it instead of appending a
        // duplicate line.
        if let flushed = lastPersistedLineByChannel[channel],
           update.id == flushed.id
            || (update.timestamp.timeIntervalSince(flushed.timestamp) <= TranscriptDedup.mergeWindowSeconds
                && TranscriptDedup.merged(previous: flushed.text, incoming: update.text) != nil) {
            return
        }
        if let pending = pendingTranscriptLineByChannel[channel] {
            if pending.id == update.id {
                // Same utterance grew (or the pre-prompt flush emitted again).
                // Update the in-memory record; don't touch disk yet.
                // Containment-guarded: the pending line may already be a
                // merged/rolled-up composite that a fragment must not clobber.
                pendingTranscriptLineByChannel[channel] = (
                    id: update.id,
                    text: TranscriptDedup.merged(previous: pending.text, incoming: update.text) ?? pending.text,
                    timestamp: update.timestamp
                )
                return
            }
            // Different id but containment-duplicate text shortly after ⇒ the
            // same utterance finalized twice (synthetic pre-flush + the
            // recognizer's own final). Merge into the pending record — same
            // rule as `TranscriptBuffer` and `ConversationContext`, so the
            // saved transcript.md matches what the user saw on screen.
            if update.timestamp.timeIntervalSince(pending.timestamp) <= TranscriptDedup.mergeWindowSeconds,
               let mergedText = TranscriptDedup.merged(previous: pending.text, incoming: update.text) {
                pendingTranscriptLineByChannel[channel] = (
                    id: update.id,
                    text: mergedText,
                    timestamp: update.timestamp
                )
                return
            }
            // Continuation of the same speaker turn (task churn finalized
            // mid-sentence) ⇒ append to the pending line, mirroring the
            // display buffer's roll-up, instead of flushing a fragment row.
            if TranscriptDedup.shouldRollUp(
                previousText: pending.text,
                previousAt: pending.timestamp,
                incomingText: update.text,
                incomingAt: update.timestamp
            ) {
                pendingTranscriptLineByChannel[channel] = (
                    id: update.id,
                    text: TranscriptDedup.rolledUp(previousText: pending.text, incomingText: update.text),
                    timestamp: update.timestamp
                )
                return
            }
            // Genuinely new utterance ⇒ the previous one is done. Flush it.
            await persistPendingTranscriptLine(channel: channel, pending: pending)
        }
        pendingTranscriptLineByChannel[channel] = (
            id: update.id,
            text: update.text,
            timestamp: update.timestamp
        )
    }

    /// Flush every channel's pending transcript line to disk. Called on stop
    /// so the last utterance of a session — which by definition has no
    /// "next segment" to push it out — still makes it into transcript.md.
    private func flushPendingTranscriptLines() async {
        let drained = pendingTranscriptLineByChannel
        pendingTranscriptLineByChannel.removeAll()
        for (channel, pending) in drained {
            await persistPendingTranscriptLine(channel: channel, pending: pending)
        }
    }

    private func persistPendingTranscriptLine(
        channel: AudioChannel,
        pending: (id: UUID, text: String, timestamp: Date)
    ) async {
        guard let sessionID = currentSession?.id else { return }
        lastPersistedLineByChannel[channel] = pending
        await SessionStore.shared.appendTranscriptLine(
            channel: channel,
            text: pending.text,
            at: pending.timestamp,
            to: sessionID
        )
    }

    /// Force the active transcriber to flush any in-progress partials as
    /// synthetic finals, then synchronously absorb them into `ConversationContext`
    /// before we snapshot for a prompt build. Without this, a user who speaks
    /// and then immediately asks the AI gets "I don't know what you said" —
    /// SFSpeech doesn't naturally emit `isFinal=true` until it hits its silence
    /// timeout (~30–60s later), and `context.absorb` only ingests finals.
    ///
    /// Direct absorb (rather than relying on the async transcripts-stream
    /// consumer) is essential: we need the context snapshot taken immediately
    /// after this call to include the freshly-flushed lines.
    private func absorbPendingTranscripts() async {
        guard let transcriber else { return }
        let pendings = transcriber.collectPendingFinals()
        for update in pendings {
            // Respect the same per-channel inclusion gates the normal consumer
            // applies — system-audio prompt inclusion can be toggled off in
            // Settings, in which case the model shouldn't see system lines.
            let shouldAbsorb: Bool
            if update.channel == .system {
                shouldAbsorb = settings.includeSystemAudioInPrompt
            } else {
                shouldAbsorb = true
            }
            if shouldAbsorb {
                await context.absorb(update)
            }
        }
    }

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
