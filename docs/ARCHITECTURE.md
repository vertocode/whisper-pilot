# Architecture

This document describes the runtime data flow and the responsibilities of each module. Read the README first.

Whisper Pilot is a system-wide AI co-pilot for macOS. It captures audio (and optionally a screenshot) from anywhere on your Mac, transcribes locally, holds rolling context, and streams an LLM response into a translucent overlay. The architecture optimizes for three things: end-to-end latency, module isolation, and substitutability.

## Goals

1. **Streaming top to bottom.** Audio frames, transcript hypotheses, LLM tokens, UI updates — everything flows as it arrives. No batch processing.
2. **Module isolation.** Every domain (audio, transcription, AI, sessions, …) is behind a small protocol. The wiring lives in `AppCoordinator` and nowhere else.
3. **Substitutable parts.** Swapping in WhisperKit, Ollama, a smarter VAD, a learned question detector — each is one file plus one line in the coordinator.

## Module map

```
Sources/WhisperPilot/
├── App/             // Entry point, AppDelegate, AppCoordinator (the only file that wires concrete types)
├── Audio/           // System audio (ScreenCaptureKit) + microphone (AVAudioEngine), VAD, mixer
├── Transcription/   // Streaming speech-to-text with channel attribution
├── Context/         // Rolling conversation memory + topic state
├── Triggers/        // Question detection + cooldown / debounce policy
├── AI/              // Provider protocol + Gemini implementation (multimodal-aware)
├── Overlay/         // Floating panel window + SwiftUI views (header, chat lane, transcript lane, composer)
├── Settings/        // Preferences view, persistent store, Keychain helper
├── Permissions/     // Microphone, Speech Recognition, system audio, Screen Recording
├── Onboarding/      // The only place permissions are requested, plus optional AI-provider setup
├── Persistence/     // SessionStore — disk-backed sessions with markdown transcripts
├── Sessions/        // SessionsWindow — launch screen + resume UI
└── MenuBar/         // Status item + menu
```

## Lifecycle

1. App launches → `WhisperPilotApp` (SwiftUI) → `AppDelegate.applicationDidFinishLaunching`. First it checks for another running copy with the same bundle id (`SingleInstance`): the older copy wins, the newer one asks macOS to reopen it and quits before touching the log or settings. Opening the app again while it runs (Finder, Spotlight) triggers `applicationShouldHandleReopen`, which shows Onboarding or Sessions.
2. `AppDelegate` constructs `AppCoordinator`, the overlay window (hidden), and the Sessions window, then refreshes the permission snapshot.
3. Onboarding opens first when a first run (or a newer onboarding version) has something missing, or when an updated build needs the Keychain approved again. It asks for everything in one screen, each with its reason: Microphone (only if mic capture is on), Speech Recognition, system audio, Screen Recording (optional on the Process Tap path, required when ScreenCaptureKit is used) and Keychain access. "Set up later" or closing the window is remembered for the current build.
4. Picking a session calls `coordinator.useSession(_:resumed:)`, which seeds `ConversationContext` (with prior markdown if resumed), and shows the overlay.
5. The user clicks ▶ Play → `coordinator.startListening()` never opens a system permission dialog: a missing permission stops it with a banner and an "Open Setup" button. Otherwise it starts the transcriber, system + microphone capture, and wires the pipeline. Transcription works without an AI key.

## Data flow

### 1. Capture

`SystemAudioCapture` uses `SCStream` from ScreenCaptureKit with `capturesAudio = true` to receive system audio. `MicrophoneCapture` uses `AVAudioEngine`'s input node tap. Both convert to a canonical 16 kHz mono PCM format via `AVAudioConverter`, attaching the `AudioChannel` (`.system` / `.microphone`) on every frame.

`AudioMixer` consumes both `AsyncStream<AudioFrame>` instances and merges them into a single ordered stream — channels are kept distinct, never summed, so transcription stays attributable.

`VoiceActivityDetector` is a per-channel energy-threshold VAD with hangover. It emits `.speechStarted` / `.speechEnded` events the trigger engine uses to know when to fire after a question.

### 2. Transcription

`TranscriptionProvider` is a small protocol:

```swift
protocol TranscriptionProvider {
    func start() async throws
    func stop()
    func feed(_ buffer: AVAudioPCMBuffer, channel: AudioChannel)
    var transcripts: AsyncStream<TranscriptUpdate> { get }
}
```

`TranscriptUpdate` carries `(segmentId, text, isFinal, channel, timestamp)` — `channel` is preserved end-to-end so the overlay shows `OTHER:` vs `ME:` and the trigger engine can ignore the user's own utterances.

Engine selection is automatic — there is no user-facing setting — and goes best-first:

1. **`ParakeetTranscriber`** (English locales): FluidAudio's Parakeet Unified 0.6B CoreML engine, one `StreamingUnifiedAsrManager` per channel on the Neural Engine. Chosen for transcript quality: 1.79% aggregate WER on LibriSpeech test-clean *with punctuation and capitalization* — the accuracy class of Meet/Teams server captions, and well ahead of the Apple engines. True streaming (~2 s latency), designed for hour-long sessions. The engine emits one continuous token stream with per-token audio timings; `TranscriptStreamSegmenter` owns the cutting rules that turn it into utterance-sized lines (pause-based gap cut on decoder timings, idle cut against the decoded frontier, length cut for pauseless monologues). Models (~600 MB) auto-download from Hugging Face on first use, cached under Application Support/FluidAudio; failure (offline first launch, unsupported hardware) falls through to the Apple engines, and the overlay says so with the reason (`EngineFallbackNote`), so a lower-accuracy engine is never a surprise.
2. **`SpeechAnalyzerTranscriber`** (macOS 26+): Apple's long-form `SpeechAnalyzer`/`SpeechTranscriber` framework. Handles every locale Apple ships a model for.
3. **`AppleSpeechTranscriber`** (older systems): two `SFSpeechRecognizer` pipes in parallel — one per channel — cycling recognition tasks at VAD utterance boundaries and trimming replay overlap at task seams. Always on-device (`requiresOnDeviceRecognition = true`): a locale with no on-device model stops with `TranscriberError.onDeviceUnavailable` instead of sending audio to Apple's servers.

Transcript text is never written to `runtime.log`; transcriber log lines carry ids, lengths and timings only.

`TranscriptBuffer` is an actor holding the live-caption display model: finalized segments are append-only and immutable, and each channel has at most one volatile (in-progress) segment that partial hypotheses replace wholesale. A final on a channel consumes that channel's volatile slot, and consecutive near-duplicate finals are merged. The buffer publishes its current state to `OverlayState`; finalized lines flow to `ConversationContext`.

### 3. Context

`ConversationContext` is the rolling memory the LLM sees. It holds:

- The last N seconds of finalized transcript (default 90 s, ~600 tokens for normal-paced conversation).
- Extracted topics (kept across turns so we don't keep rediscovering them).
- Detected entities and technologies.
- Optional **prior session markdown** when a session was resumed — surfaced as a separate "Prior session transcript / Prior session AI chat" block so the model knows it's older context.

`TopicExtractor` runs cheaply via `NLTagger` per finalized segment.

### 4. Triggers

`QuestionDetector` scores each finalized system-channel segment based on:

- Question marks + interrogative starters (`how`, `what`, `why`, `can you`, `could you`, …).
- Modal leads (`tell me about`, `walk me through`, …).
- Direct address (`you`, `your`).
- Length thresholds (very short or very long utterances are downweighted).

`TriggerEngine` decides whether to actually fire:

- Score ≥ `triggerThreshold` (default 0.6).
- Cooldown since last fire respected (default 8 s).
- A minimum VAD silence after the question — default 700 ms — gives the user a chance to start answering before we suggest.
- In-flight completions are cancelled when a new trigger fires (latest question wins).

When the user has set the AI to Paused, the trigger engine's events still come through but the coordinator drops them on the floor. Only manual composer prompts go through.

### 5. AI

`AIProvider` is intentionally tight:

```swift
protocol AIProvider {
    func streamCompletion(prompt: Prompt) -> AsyncThrowingStream<String, Error>
    func isQuestionToAnswer(_ text: String) async throws -> Bool
    func extractTopics(from text: String) async throws -> [String]
    func summarize(_ text: String) async throws -> String
}
```

`Prompt` carries `systemInstruction`, `context`, `question`, `style`, and an optional `imageJPEGBase64` for multimodal input. `GeminiProvider` packages those into `streamGenerateContent?alt=sse` requests, parses the SSE stream of partial JSON via `URLSession.bytes(for:)`, and yields decoded text deltas. When `imageJPEGBase64` is set, it ships as a second `inline_data` part so vision-capable models reason about the screenshot.

Both providers (`GeminiProvider`, `AnthropicProvider`) share the same failure handling. `AIRetryPolicy.withRetry` retries once, and only before any text has reached the user, for 429, 5xx, Anthropic overloaded events and dropped connections; it honors `Retry-After` up to 8 seconds. A stream that yields no text and only undecodable chunks fails with `unexpectedFormat` instead of looking like a network drop. Error bodies are cut to one line by `AIErrorBody`. For auto-detected questions, an identical error note is shown once (`RepeatedNote`).

`PromptBuilder` is the only place that decides how transcript + history + screenshot context get composed. Three entry points:

- `build(...)` — for detected questions on the call.
- `buildAutoSend(...)` — for the periodic timer; asks for a recap + suggested follow-up.
- `buildUserQuery(..., withScreenshot:)` — for composer messages; flips a hint in the system instruction when a screenshot accompanies the prompt.

All three include the recent meeting transcript, the prior assistant↔user chat (last 10 turns), topics, and prior session markdown if resumed.

### 6. Overlay

`OverlayWindowController` owns a real `NSWindow` (not `NSPanel`) so window managers like BetterSnapTool, Rectangle, and macOS's own snap-to-edge can manage and resize it. The chrome is hidden (`titlebarAppearsTransparent`, `titleVisibility = .hidden`, all traffic lights `.isHidden = true`) so it still looks borderless. The window level is `.floating` when *Always on top* is enabled.

`OverlayView` lays out four lanes that update independently:

- **Header** — logo, status pill (`Idle` / `Listening` / `Thinking` / `Speaking`), live counters (`X audio · Y transcripts`), and the action cluster: ▶ listening toggle, ⏸ AI pause, ⚙ settings, ✕ hide.
- **Banner** — appears for `.needsAPIKey`, `.needsPermission(...)`, or `.error(...)`. Each banner provides an actionable button (Open Settings / Open Setup / Open Privacy Settings).
- **Chat lane** — `[ChatMessage]` bubbles with role badges (You / Assistant / System) and origin badges (`from detected question`, `auto-send`).
- **Transcript lane** — recent transcript segments with channel attribution.
- **Composer** — text field + 📤 send + 👁 *See my screen* toggle. Toggle resets after each send so attaching a screenshot is always deliberate.

`OverlayState` is the `@MainActor` `ObservableObject` the coordinator pushes into.

### 7. Sessions & persistence

`SessionStore` is an `actor` that owns `~/Library/Application Support/<bundle>/sessions/`. Each session is a folder named `<slug>-YYYY-MM-DD-HH-mm/` containing `transcript.md`, `chat.md`, and `metadata.json`. Files are appended live as transcripts finalize and chat turns complete — no batched flush, no in-memory queue. Appends return a `Result`; `SaveHealth` turns the first failure (disk full, no permission, folder deleted) into one persistent overlay banner and reports when saving recovers. A reply that was cancelled or cut off is still saved to `chat.md`, tagged `(incomplete)` (`AssistantTurnText`). The session list re-reads a transcript or chat file only when its size or modification time changed.

`SessionsWindow` is the launch UI. It lists past sessions (sorted by most-recently-used), supports per-row Resume / Open in Finder / Delete, and prominently displays a tip about the token-cost trade-off of resuming.

On resume, the coordinator loads `transcript.md` and `chat.md` as raw markdown and hands both to `ConversationContext.seedFromMarkdown(...)`. Subsequent prompts include "Prior session transcript (resumed)" and "Prior session AI chat (resumed)" sections so the model knows it's older context.

### 8. Settings & permissions

`SettingsStore` wraps `UserDefaults`. Gemini and Claude API keys live in one Keychain item, reached through the small `SecretStore` protocol (`SystemSecretStore` wraps `KeychainHelper`; tests inject a fake, so no test can raise a dialog). `PermissionsManager` owns permission checks, requests, and Privacy & Security deep links; the raw-status-to-`PermissionStatus` rules live in `PermissionMapping` so they can be tested without a dialog.

**Permissions are requested in one place, onboarding.** Nothing else may raise a macOS dialog: Play, Settings, Sessions and the overlay only read state. Screen Recording and system audio have no public "am I allowed" API, so the manager remembers its own request. The Keychain is the same: `SettingsStore` reads the secret only in `unlockStoredKeys()` (onboarding, or the "Allow Keychain access" button) and, at launch, only for a build the user already approved (`KeychainHelper.buildIdentity`, the code-signature hash, stored in `keychain.approvedBuild`). Every other access reads the in-memory copy. An updated ad-hoc build has a new hash, so macOS asks again; onboarding reopens once for that, with the reason.

`OnboardingView` explains why each permission is needed, shows a specific message when one is refused (or blocked by a device policy), and lets the user save one AI-provider key to Keychain or defer it. `onboarding.completedVersion` (see `SettingsStore.currentOnboardingVersion`) records what the user finished; bump it when onboarding starts asking for something new.

The Settings window is owned by `AppDelegate`, not by SwiftUI's `Settings { }` scene — the magic `showSettingsWindow:` action selector silently no-ops on accessory / `LSUIElement` apps in recent SDKs, so we manage our own `NSWindow` and skip the routing entirely.

## Threading model

- **Audio queue** — `SystemAudioCapture` and `MicrophoneCapture` deliver buffers on a dedicated `DispatchQueue`. They never touch UI.
- **Transcription** — `AppleSpeechTranscriber` is a class with two internal channel pipes; the `recognitionTask` callback marshals updates into the public `AsyncStream`.
- **Trigger engine** — actor. State (cooldown, last fire, pending candidate) is fully contained.
- **AI calls** — plain `Task` chains. Cancellable. The in-flight task is stored on the coordinator so a new trigger or composer submission cancels the old one.
- **UI** — every observable state mutation hops to `@MainActor`.
- **Persistence** — `SessionStore` is an actor; appends are serialized.
- **Long sessions** — while listening, `ListeningActivity` holds a `userInitiatedAllowingIdleSystemSleep` activity so App Nap does not throttle timers and network calls behind a meeting window. After the Mac wakes with a session running, the coordinator waits 5 seconds and restarts capture if no new audio frame arrived (`WakeRecovery`).
- **Log file** — `CrashLogger` writes from its own queue and trims `runtime.log` in place to the newest 256 KB once it passes 1 MB.

## Why these choices

- **Parakeet Unified over WhisperKit for the quality engine.** Better English WER than Whisper large-v3-turbo, true streaming instead of chunk-re-decode, no hallucination-on-silence failure mode, and an int8 encoder that lives on the ANE. The Apple engines stay as zero-download fallbacks (non-English locales, offline first launch), and the `TranscriptionProvider` protocol keeps any future engine a single conformance.
- **Gemini Flash over Pro by default.** Latency is the dominant UX signal here. Flash's first-token latency on streamed completion is consistently sub-second.
- **No SwiftData / no Core Data.** The persistence model is markdown files on disk. Plain text outlives any database we'd pick. If we ever need indexing, we'll add it on top of the same files.
- **`NSWindow` (not `NSPanel`) for the overlay.** Window managers refuse to touch panels and borderless windows. Real `NSWindow` with hidden chrome gives both the borderless look and full window-manager support.
- **Sessions-first working screen.** After one-time onboarding, the disk-backed session is the unit of work. Forcing the user to pick or create one removes the ambiguity of "what is this transcript attached to?"

## Extending

To add a new LLM provider, conform to `AIProvider` and register it in `AppCoordinator.startListening()`. To add a new transcriber, conform to `TranscriptionProvider` and likewise. The wiring layer is the only place that knows about concrete types.

To add a new context source — e.g. clipboard contents, browser tab title, Apple Notes — extend `ConversationSnapshot` and have `PromptBuilder.contextBlock(...)` include it. The pipeline downstream needs no changes.

## Non-goals

- A chat UI. We have a composer for explicit prompts, but the assistant is not a chatbot. Scrollback for a conversation is fine; full message threads with branching are out of scope.
- A hosted backend. There isn't one and there won't be one. If we ever need shared state across devices, it'll be behind a provider protocol the user can swap.
- iOS. iOS doesn't expose system audio capture; the product fundamentally requires a desktop OS.
