# Contributing

Thanks for the interest. Whisper Pilot is a small, focused, intentionally non-magical macOS app — most contributions slot into a single module without touching anything else.

## Project setup

```bash
brew install xcodegen
./bin/regenerate            # wraps `xcodegen generate`
open WhisperPilot.xcodeproj
```

Run with ⌘R. The project does **not** require a paid Apple Developer account; ad-hoc signing is sufficient.

After every `git pull`, run `./bin/regenerate` so the `.xcodeproj` picks up any added or removed files. Skip it and Xcode will surface "Cannot find … in scope" errors for new types.

You can also type-check and run smoke tests without Xcode:

```bash
swift build                  # type-checks the whole module under Swift 6 strict concurrency
swift run SmokeTests         # runs the pure-logic test suite (29 assertions)
```

`swift build` won't produce a runnable `.app` — entitlements and `Info.plist` live in `Project.yml`.

### Stop macOS from re-asking for permissions on every rebuild

By default the project signs ad-hoc (`CODE_SIGN_IDENTITY = "-"`). Every rebuild changes the binary hash, and macOS's TCC database treats the new build as a different app — so Microphone / Screen Recording / Speech Recognition grants get wiped and re-prompted (with your admin password) every time. That gets old fast.

Fix it once with a free Apple ID Personal Team:

1. Xcode → **Settings → Accounts** → **+** → sign in with your Apple ID (free; no paid Developer Program needed).
2. Select the **WhisperPilot** target → **Signing & Capabilities**.
3. Change **Team** from `None` to your name (Personal Team). Xcode generates a stable certificate.
4. Build once. macOS prompts for permissions one final time. Grant them.
5. From then on, rebuilds reuse the same code signature → TCC remembers your permissions → no more password prompts.

This works because TCC keys Personal Team-signed binaries by stable identity rather than content hash.

## How to find your way around

Read [`docs/ARCHITECTURE.md`](ARCHITECTURE.md) first. It maps every module to the runtime data flow. The fastest way to understand the codebase is to follow a single audio frame from `SystemAudioCapture` to the overlay, and a single composer submission from `OverlayView` to `GeminiProvider`.

Modules are protocol-first. If you want to swap something out (LLM, transcriber, VAD), you almost certainly only need to:

1. Conform to the protocol in the relevant module.
2. Register your implementation in `AppCoordinator`.

## Conventions

- **Swift 5.9+, structured concurrency.** Prefer `async`/`await`, `AsyncStream`, actors. Avoid `DispatchQueue` outside the audio capture path (where it's required by the underlying APIs).
- **Single responsibility per file.** A file containing two top-level types is usually two files. Two exceptions in the current tree (`OverlayView.swift`, `OverlayWindowController.swift`) co-locate small types because they're consumed exclusively together.
- **No magic globals.** Dependencies are injected through initializers. `AppCoordinator` is the only place that constructs concrete types.
- **No comments that restate the code.** Comments explain *why*, not *what*. Prefer good names over comments.
- **Privacy and explicitness over convenience.** No telemetry. No silent network calls. Anything that leaves the device should be obviously triggered by the user.

## Testing

There are two test surfaces:

1. **Smoke tests** (`Tools/SmokeTests/SmokeTestRunner.swift`) — pure-logic assertions for `QuestionDetector`, `TopicExtractor`, `ConversationContext`, `PromptBuilder`, `TriggerEngine`. Runnable via `swift run SmokeTests` even without Xcode. Add to it when you change a heuristic.
2. **Manual end-to-end** — open Xcode, run the app, talk to your Mac. The architecture is realtime; some classes (audio capture, ScreenCaptureKit, `SFSpeechRecognizer`) only really exercise live.

XCTest / swift-testing target is on the TODO list once Apple ships the Testing framework reliably with command-line tools — currently CLT ships an incomplete `Testing.framework` (no `_Testing_Foundation`), so the smoke runner uses a tiny custom harness.

## Pull requests

- One concern per PR. A trigger heuristic tweak and a new LLM provider should not share a PR.
- Update `docs/ARCHITECTURE.md` if you add a new module or change a public protocol.
- Run `swift build` and `swift run SmokeTests` before submitting. If you touch a heuristic, add an assertion.
- Conventional commit message: `feat: …`, `fix: …`, `refactor: …`, `chore: …`, `docs: …`, `test: …`.

## Areas that especially need help

- **WhisperKit transcriber** — drop-in `TranscriptionProvider` using the WhisperKit Swift package. Should let users opt into higher-quality on-device transcription.
- **Local LLM provider** — `OllamaProvider` against a user-run Ollama instance.
- **Speaker diarization** — beyond the system-vs-mic channel split.
- **Trigger engine tests** — the heuristics are hand-rolled and brittle. Snapshot tests on real fixtures would catch regressions.
- **A real app icon** — the current logo is a placeholder.
- **Multi-display / virtual audio output robustness** — `ScreenCaptureKit` audio capture has edge cases when the user routes output through BlackHole or has multiple displays. Reproduce + fix needed.

## Getting in touch

Open an issue on GitHub. For larger architectural proposals, open a draft PR with the design described in the body and we'll iterate before code lands.
