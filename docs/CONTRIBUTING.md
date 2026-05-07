# Contributing

Thanks for the interest. This is an open-source ambient AI assistant — small, focused, and intentionally non-magical inside.

## Project setup

```bash
brew install xcodegen
xcodegen generate
open WhisperPilot.xcodeproj
```

Run with `⌘R`. The project does **not** require a paid Apple Developer account; ad-hoc signing is sufficient for local development.

## How to find your way around

Read [`docs/ARCHITECTURE.md`](ARCHITECTURE.md) first. It maps every module to the runtime data flow. The fastest way to understand the codebase is to follow a single audio frame from `SystemAudioCapture` to the overlay.

Modules are protocol-first. If you want to swap something out (LLM, transcriber, VAD), you almost certainly only need to:

1. Conform to the protocol in the relevant module
2. Register your implementation in `AppCoordinator`

## Conventions

- **Swift 5.9+, structured concurrency.** Prefer `async`/`await`, `AsyncStream`, actors. Avoid `DispatchQueue` outside the audio pipeline.
- **Single responsibility per file.** A file containing two top-level types is usually two files.
- **No magic globals.** Dependencies are injected through initializers. `AppCoordinator` is the only place that constructs concrete types.
- **No comments that restate the code.** Comments explain *why*, not *what*.
- **Tests live next to the module.** `Tests/AudioTests/...`, etc. (test target is in roadmap; happy to take a PR.)

## Pull requests

- One concern per PR. A trigger heuristic tweak and a new LLM provider should not share a PR.
- Update `docs/ARCHITECTURE.md` if you add a new module or change a public protocol.
- Conventional commit message: `feat: …`, `fix: …`, `refactor: …`, `chore: …`.

## Areas that need help

- WhisperKit transcriber implementation
- Local LLM provider (Ollama)
- Speaker diarization
- Tests for the trigger engine (the heuristics are hand-rolled and brittle)
- A real icon
