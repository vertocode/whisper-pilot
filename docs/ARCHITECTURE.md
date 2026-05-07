# Architecture

This document describes the runtime data flow and the responsibilities of each module. It assumes you have read the README.

## Goals

1. **Streaming top to bottom.** Audio frames, transcript hypotheses, LLM tokens, UI updates — everything flows as it arrives.
2. **Module isolation.** Every domain (audio, transcription, AI, …) is behind a small protocol. The wiring lives in `AppCoordinator` and nowhere else.
3. **No surprises.** Each module is small, single-purpose, and unit-testable in isolation.

## Module map

```
Sources/WhisperPilot/
├── App/             // Entry point, AppDelegate, AppCoordinator (wires modules)
├── Audio/           // Capture pipeline (system + mic), VAD
├── Transcription/   // Streaming speech-to-text
├── Context/         // Rolling conversation memory + topic state
├── Triggers/        // Question detection + cooldown / debounce policy
├── AI/              // Provider protocol + Gemini implementation
├── Overlay/         // Floating panel window + SwiftUI views
├── Settings/        // Preferences view, persistent store, Keychain helper
├── Permissions/     // Microphone + Screen Recording flow
└── Persistence/     // (future) session log
```

## Data flow

### 1. Capture

`SystemAudioCapture` uses `SCStream` from ScreenCaptureKit to receive system audio frames. `MicrophoneCapture` uses `AVAudioEngine` to tap the input node. Both produce `AVAudioPCMBuffer` instances on a dedicated audio queue.

`AudioMixer` consumes both streams. When the user has the microphone enabled it forwards both as separate logical channels (we do **not** sum them yet; see "Speaker diarization" in the roadmap). When mic is disabled, only system audio is forwarded.

`VoiceActivityDetector` wraps the stream with a simple energy-based detector. It emits `.speechStarted`, `.speechEnded(duration:)` events alongside the buffers. The `Triggers` module consumes those events to know when a question has finished.

### 2. Transcription

`TranscriptionProvider` is a protocol:

```swift
protocol TranscriptionProvider {
    func start() async throws
    func stop()
    func feed(_ buffer: AVAudioPCMBuffer)
    var transcripts: AsyncStream<TranscriptUpdate> { get }
}
```

`TranscriptUpdate` carries `(segmentId, text, isFinal, timestamp, channel)` — `channel` is `system` or `microphone` so the consumer can attribute speakers later.

The default implementation is `AppleSpeechTranscriber` (uses `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`). It is free, native, and on-device on macOS 14+. Drop-in alternatives planned: `WhisperKitTranscriber`, `WhisperCppTranscriber`.

Updates land in `TranscriptBuffer`, a rolling buffer keyed by segment ID. Partial hypotheses overwrite their slot until they're finalized. The buffer publishes its current state to `ConversationContext` and to the overlay.

### 3. Context

`ConversationContext` is the rolling memory the LLM sees. It holds:

- The last N seconds of transcript (default 90s, ~600 tokens for a normal-paced conversation)
- Extracted topics (tracked across turns so we don't keep re-discovering them)
- Detected entities and technologies
- A digest of older content so we don't blow the context window

`TopicExtractor` runs cheaply on every finalized segment: keyword-based for v1, embedding-based later.

### 4. Triggers

`QuestionDetector` looks at finalized transcript segments and scores them on:

- Question marks / interrogative starters ("how", "what", "can you", "could you", "do you", "would you", "why", "when")
- Pronouns directed at the listener ("you", "your")
- Pause length after the segment (from VAD)
- Sentence length (very short utterances are usually filler)

`TriggerEngine` decides whether to actually fire:

- Score must clear `triggerThreshold` (default 0.6)
- Cooldown since last fire must be respected (default 8s)
- A minimum VAD silence after the question must have passed (default 700ms — gives the user a chance to start answering before we suggest)
- If a fire is in flight when a new candidate arrives, the in-flight call is cancelled and the new one takes priority (latest question wins)

### 5. AI

`AIProvider` is small on purpose:

```swift
protocol AIProvider {
    func streamCompletion(prompt: Prompt) -> AsyncThrowingStream<String, Error>
    func classifyQuestion(_ text: String) async throws -> QuestionClass
    func extractTopics(from text: String) async throws -> [String]
    func summarize(_ text: String) async throws -> String
}
```

`GeminiProvider` implements it via the `streamGenerateContent` REST endpoint. The streaming endpoint emits Server-Sent-Event chunks of partial JSON; we parse incrementally with `URLSession.bytes(for:)` and yield decoded text deltas.

`PromptBuilder` assembles the prompt from `ConversationContext` + the detected question + the user's chosen response style. It deliberately keeps the system instruction short (latency).

`classifyQuestion` and `extractTopics` are also Gemini calls but with `responseMimeType: application/json` for structured output.

### 6. Overlay

`OverlayWindowController` owns an `NSPanel` configured as:

- Level `.floating` (or `.statusBar` when "always on top" is on)
- `.nonactivatingPanel` style mask (we don't steal focus from the call)
- `isMovableByWindowBackground = true`
- `ignoresMouseEvents = true` when click-through is enabled

`OverlayView` renders four lanes that update independently:

- **Live transcript** — last few seconds, ghosted older lines
- **AI response** — the streaming token output, with a typing indicator
- **Suggested follow-ups** — short tap-to-pin list
- **State** — listening / thinking / speaking / idle

`OverlayState` is an `@MainActor` `ObservableObject` that the coordinator pushes updates into.

### 7. Settings & Permissions

`SettingsStore` wraps `UserDefaults`. `KeychainHelper` reads/writes the API key. `PermissionsManager` walks the user through both system permission grants on first launch.

## Threading model

- **Audio queue** — `SystemAudioCapture` and `MicrophoneCapture` deliver buffers on a dedicated `DispatchQueue`. They do not touch UI.
- **Transcription actor** — `AppleSpeechTranscriber` is an actor. It owns the recognizer and the `AsyncStream` continuation.
- **Trigger engine** — also an actor. State (cooldown, last fire) is contained.
- **AI calls** — plain `Task` chains. Cancellable, in-flight call is stored on the coordinator so a new trigger can cancel it.
- **UI** — every observable state mutation hops to `@MainActor`.

## Why these choices

- **`SFSpeechRecognizer` over WhisperKit on day one.** No model download, no Core ML compile step, works on first launch. The `TranscriptionProvider` protocol means swapping is trivial when we want the quality bump.
- **Gemini Flash over Pro on day one.** Latency is the dominant UX signal here. Flash's first-token latency on streamed completion is consistently sub-second.
- **No SwiftData / no Core Data.** There is nothing persistent in v1 except settings. Conversation log persistence is in the roadmap and will be a single module addition.
- **Floating panel, not a regular window.** A regular `NSWindow` steals focus and disrupts the meeting. `NSPanel` with `.nonactivating` does not.

## Extending

To add a new LLM provider, conform to `AIProvider` and register it in `AppCoordinator.makeAIProvider()`. To add a new transcriber, conform to `TranscriptionProvider` and likewise. The wiring layer is the only place that knows about concrete types.

## Non-goals

- A chat UI. There is no input field for the user to type into. Adding one would be feature creep that compromises the ambient design.
- Multi-language conversation transcription on day one. `SFSpeechRecognizer` is locale-bound; we expose locale in settings but assume one language per session.
- Server-side anything. There is no backend. If we ever need shared state (cross-device memory), it will live behind a provider protocol.
