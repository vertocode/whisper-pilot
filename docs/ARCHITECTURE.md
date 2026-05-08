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
├── Permissions/     // Microphone + Screen Recording flow
├── Persistence/     // SessionStore — disk-backed sessions with markdown transcripts
├── Sessions/        // SessionsWindow — launch screen + resume UI
└── MenuBar/         // Status item + menu
```

## Lifecycle

1. App launches → `WhisperPilotApp` (SwiftUI) → `AppDelegate.applicationDidFinishLaunching`.
2. `AppDelegate` constructs `AppCoordinator`, the overlay window (hidden), and the **Sessions window** (visible). The user picks or creates a session.
3. Picking a session calls `coordinator.useSession(_:resumed:)`, which seeds `ConversationContext` (with prior markdown if resumed), and shows the overlay.
4. The user clicks ▶ Play → `coordinator.startListening()` walks gates: Screen Recording probe, mic permission (if requested), API key presence. Then it starts the transcriber, the system + microphone capture, and wires the pipeline.

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

The default implementation, `AppleSpeechTranscriber`, runs two `SFSpeechRecognizer` pipes in parallel — one per channel — with `requiresOnDeviceRecognition` set when the locale supports it. Drop-in alternatives planned: `WhisperKitTranscriber` (Core ML, runs on the ANE on Apple Silicon), `WhisperCppTranscriber`.

`TranscriptBuffer` is a rolling actor-backed buffer keyed by segment ID. Partial hypotheses overwrite their slot until they're finalized. The buffer publishes its current state to `OverlayState` and its finalized lines to `ConversationContext`.

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
    func classifyQuestion(_ text: String) async throws -> QuestionClass
    func extractTopics(from text: String) async throws -> [String]
    func summarize(_ text: String) async throws -> String
}
```

`Prompt` carries `systemInstruction`, `context`, `question`, `style`, and an optional `imageJPEGBase64` for multimodal input. `GeminiProvider` packages those into `streamGenerateContent?alt=sse` requests, parses the SSE stream of partial JSON via `URLSession.bytes(for:)`, and yields decoded text deltas. When `imageJPEGBase64` is set, it ships as a second `inline_data` part so vision-capable models reason about the screenshot.

`PromptBuilder` is the only place that decides how transcript + history + screenshot context get composed. Three entry points:

- `build(...)` — for detected questions on the call.
- `buildAutoSend(...)` — for the periodic timer; asks for a recap + suggested follow-up.
- `buildUserQuery(..., withScreenshot:)` — for composer messages; flips a hint in the system instruction when a screenshot accompanies the prompt.

All three include the recent meeting transcript, the prior assistant↔user chat (last 10 turns), topics, and prior session markdown if resumed.

### 6. Overlay

`OverlayWindowController` owns a real `NSWindow` (not `NSPanel`) so window managers like BetterSnapTool, Rectangle, and macOS's own snap-to-edge can manage and resize it. The chrome is hidden (`titlebarAppearsTransparent`, `titleVisibility = .hidden`, all traffic lights `.isHidden = true`) so it still looks borderless. The window level is `.floating` when *Always on top* is enabled.

`OverlayView` lays out four lanes that update independently:

- **Header** — logo, status pill (`Idle` / `Listening` / `Thinking` / `Speaking`), live counters (`X audio · Y transcripts`), and the action cluster: ▶ listening toggle, ⏸ AI pause, ⚙ settings, ✕ hide.
- **Banner** — appears for `.needsAPIKey`, `.needsPermission(...)`, or `.error(...)`. Each banner provides an actionable button (Open Settings / Open Privacy Settings).
- **Chat lane** — `[ChatMessage]` bubbles with role badges (You / Assistant / System) and origin badges (`from detected question`, `auto-send`).
- **Transcript lane** — recent transcript segments with channel attribution.
- **Composer** — text field + 📤 send + 👁 *See my screen* toggle. Toggle resets after each send so attaching a screenshot is always deliberate.

`OverlayState` is the `@MainActor` `ObservableObject` the coordinator pushes into.

### 7. Sessions & persistence

`SessionStore` is an `actor` that owns `~/Library/Application Support/<bundle>/sessions/`. Each session is a folder named `<slug>-YYYY-MM-DD-HH-mm/` containing `transcript.md`, `chat.md`, and `metadata.json`. Files are appended live as transcripts finalize and chat turns complete — no batched flush, no in-memory queue.

`SessionsWindow` is the launch UI. It lists past sessions (sorted by most-recently-used), supports per-row Resume / Open in Finder / Delete, and prominently displays a tip about the token-cost trade-off of resuming.

On resume, the coordinator loads `transcript.md` and `chat.md` as raw markdown and hands both to `ConversationContext.seedFromMarkdown(...)`. Subsequent prompts include "Prior session transcript (resumed)" and "Prior session AI chat (resumed)" sections so the model knows it's older context.

### 8. Settings & permissions

`SettingsStore` wraps `UserDefaults`. `KeychainHelper` reads/writes the Gemini API key. `PermissionsManager` walks the user through both system permission grants on first launch and provides a deep link to the Privacy & Security pane for recovery (TCC denials are easy to hit during dev).

The Settings window is owned by `AppDelegate`, not by SwiftUI's `Settings { }` scene — the magic `showSettingsWindow:` action selector silently no-ops on accessory / `LSUIElement` apps in recent SDKs, so we manage our own `NSWindow` and skip the routing entirely.

## Threading model

- **Audio queue** — `SystemAudioCapture` and `MicrophoneCapture` deliver buffers on a dedicated `DispatchQueue`. They never touch UI.
- **Transcription** — `AppleSpeechTranscriber` is a class with two internal channel pipes; the `recognitionTask` callback marshals updates into the public `AsyncStream`.
- **Trigger engine** — actor. State (cooldown, last fire, pending candidate) is fully contained.
- **AI calls** — plain `Task` chains. Cancellable. The in-flight task is stored on the coordinator so a new trigger or composer submission cancels the old one.
- **UI** — every observable state mutation hops to `@MainActor`.
- **Persistence** — `SessionStore` is an actor; appends are serialized.

## Why these choices

- **`SFSpeechRecognizer` over WhisperKit on day one.** No model download, no Core ML compile, works on first launch. The `TranscriptionProvider` protocol means swapping in WhisperKit later is a single conformance.
- **Gemini Flash over Pro by default.** Latency is the dominant UX signal here. Flash's first-token latency on streamed completion is consistently sub-second.
- **No SwiftData / no Core Data.** The persistence model is markdown files on disk. Plain text outlives any database we'd pick. If we ever need indexing, we'll add it on top of the same files.
- **`NSWindow` (not `NSPanel`) for the overlay.** Window managers refuse to touch panels and borderless windows. Real `NSWindow` with hidden chrome gives both the borderless look and full window-manager support.
- **Sessions-first launch screen.** The disk-backed session is the unit of work. Forcing the user to pick or create one removes the ambiguity of "what is this transcript attached to?"

## Extending

To add a new LLM provider, conform to `AIProvider` and register it in `AppCoordinator.startListening()`. To add a new transcriber, conform to `TranscriptionProvider` and likewise. The wiring layer is the only place that knows about concrete types.

To add a new context source — e.g. clipboard contents, browser tab title, Apple Notes — extend `ConversationSnapshot` and have `PromptBuilder.contextBlock(...)` include it. The pipeline downstream needs no changes.

## Non-goals

- A chat UI. We have a composer for explicit prompts, but the assistant is not a chatbot. Scrollback for a conversation is fine; full message threads with branching are out of scope.
- A hosted backend. There isn't one and there won't be one. If we ever need shared state across devices, it'll be behind a provider protocol the user can swap.
- iOS. iOS doesn't expose system audio capture; the product fundamentally requires a desktop OS.
