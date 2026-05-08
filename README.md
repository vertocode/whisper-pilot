<p align="center">
  <img src="Resources/Branding/whisper-logo-nobg.png" alt="Whisper Pilot" width="180" />
</p>

<h1 align="center">Whisper Pilot</h1>

<p align="center">An invisible, local-first AI co-pilot for everything you do on your Mac.</p>

Whisper Pilot listens to anything your Mac can hear — meetings, podcasts, tutorials, your own voice — transcribes it on-device in realtime, and lets you ask an AI about it from a translucent floating overlay. Type a question. Optionally let it see your screen. Get a streaming answer back, contextualized to what's actually happening.

It's tuned for live meetings (Teams, Meet, Slack, Zoom, Discord, in-browser calls), but the same pipeline works for any audio source. Pair programming, watching a Korean drama, debugging an error message in a video, capturing notes from a conference talk — the assistant doesn't care about the source.

> **Status:** alpha. The architecture is in place, sessions persist to disk as plain markdown, and the audio → transcription → trigger → AI → overlay pipeline is wired end-to-end. Many heuristics, models, and UI affordances are deliberately simple so they can be iterated quickly. See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) and [`docs/ROADMAP.md`](docs/ROADMAP.md).

## Why this exists

Existing AI assistants make you stop what you're doing: switch windows, type a prompt, paste context, wait. That's fine for a chatbot. It's wrong for anything live.

Whisper Pilot is the opposite. It's ambient. It captures what's happening on your Mac, holds it in a rolling context, and is ready when you need it — either by detecting a question and answering proactively, or because you typed something into the composer and pressed ⌘⏎.

A few examples of what that unlocks:

- **Live meetings.** Someone asks you a hard question on a Zoom call. The assistant detects the question and starts streaming an answer before you'd have alt-tabbed.
- **Tutorials and lectures.** Watching a video, hit pause, ask "what was that piece about object pools?" — the assistant has the transcript.
- **Pair programming.** Tick the *See my screen* box in the composer, ask "why is this test failing?" — the assistant gets your prompt plus a fresh screenshot.
- **Translation while watching.** Foreign-language video playing — ask "translate the last minute" or set auto-send on a 30-second interval and let it run.
- **Generic system assistant.** Anything visible or audible on your Mac is fair game. You provide your own LLM key; we provide the plumbing.

## Design principles

- **Realtime end-to-end.** Audio → transcription → trigger → LLM → UI all stream. Partial results appear immediately.
- **Local-first.** Audio never leaves the device. Transcription runs on-device via `SFSpeechRecognizer` (with `WhisperKit` planned). Only the prompt goes to the LLM, and only with your own key.
- **Bring your own key.** No backend, no telemetry, no signup. Today: Gemini. Tomorrow: Claude, GPT, Ollama — same `AIProvider` protocol.
- **Invisible by default.** Translucent floating window, optional click-through. No chat-window UX. The AI doesn't pop up — it streams quietly into a lane you can ignore.
- **Free Apple stack.** No paid Developer Program required. Ad-hoc signed, runs locally.

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon recommended (Intel works; transcription is slower)
- Xcode 15 or later
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
- A Gemini API key from [aistudio.google.com](https://aistudio.google.com/app/apikey)

## Quick start

```bash
git clone git@github.com:vertocode/whisper-pilot.git
cd whisper-pilot
brew install xcodegen
./bin/regenerate         # runs `xcodegen generate`
open WhisperPilot.xcodeproj
```

In Xcode: select the **WhisperPilot** scheme and ⌘R. The first launch shows a **Sessions window** — start a new session, give it an optional name, then click **Start new**. The overlay appears in the top-right of your screen.

A few first-run notes:

1. macOS will prompt for **Screen Recording** permission the first time you click ▶ Play. Grant it in *System Settings → Privacy & Security → Screen & System Audio Recording*. This is how ScreenCaptureKit exposes meeting audio (and how we capture the screen for the *See my screen* feature).
2. Microphone permission is only needed if you turn on *Capture microphone* in Settings.
3. Open **Settings** (⚙ icon in the overlay header) and paste your Gemini API key. Stored in the macOS Keychain, never written to disk in plaintext.

> A `Package.swift` is also committed for contributor convenience — `swift build` type-checks the whole module without Xcode and `swift run SmokeTests` runs the pure-logic test suite. **Do not** open `Package.swift` in Xcode to run the app — always go through `xcodegen` and the generated `.xcodeproj`. Run `./bin/regenerate` after every `git pull` so the project picks up new files.

## How you use it

The overlay is always available once you've picked a session.

**▶ Start listening.** Begins capturing system audio (and microphone if enabled). Status flips to "Listening", and live counters under the status pill show the number of audio frames captured and transcripts produced. The transcript lane fills in as people talk.

**Ask the AI.** Three ways:

1. **Detected questions.** When the trigger engine detects someone asking *you* a question on the call, it streams an answer into the AI lane automatically. Configurable cooldown and pause requirements keep this from being noisy.
2. **Periodic auto-send.** Set an interval in Settings → General → "Auto-send to AI" (`Off`, every 30 s, 1 min, 2 min, or 5 min). On every tick the assistant gets a recap-and-suggest-a-follow-up prompt. Skips the tick if no new transcripts have arrived since the last send.
3. **Composer.** Type a question in the box at the bottom of the overlay. ⌘⏎ to send. Multi-turn references work — "translate that", "explain more", "what did they say about X" — because the AI receives both the live transcript and the recent chat history as context.

**📸 See my screen.** Tick the small toggle next to the composer. When you submit, the overlay captures your current display via ScreenCaptureKit, downsamples it to ≤ 1280 px wide, JPEG-encodes it, and ships it as a multimodal `inline_data` part to Gemini. The model gets your text plus the image. The toggle resets after each send so it's deliberate every time.

**⏸ Pause AI.** The sparkles button in the overlay header. When paused, neither detected questions nor the auto-send timer fire — only manual composer prompts go through. Useful when you want the assistant to listen and transcribe without burning tokens.

## Sessions

Sessions are first-class. Each session lives on disk under:

```
~/Library/Application Support/com.whisperpilot.app/sessions/<slug>-YYYY-MM-DD-HH-mm/
├── transcript.md      # appended live, one block per finalized transcript segment
├── chat.md            # appended live, one heading per turn
└── metadata.json      # display name + timestamps
```

`transcript.md` and `chat.md` are plain markdown — grep them, share them, version-control them. The app doesn't need to be running for them to be useful.

The Sessions window (the launch screen, also reachable from the menu bar via *Sessions…* / ⌘S) shows your past sessions with line counts, last-used time, and per-session actions (Resume, Open in Finder, Delete).

**Resume re-includes prior content in every AI prompt.** The blue tip in the Sessions window says it explicitly: prefer a fresh session unless you actually need the prior context — it's cheaper in tokens.

## Architecture at a glance

```
                              ┌──────────────┐
   ScreenCaptureKit  ───┐     │              │
                         ├──►  AudioMixer ──► VAD ──► Transcriber ──► TranscriptBuffer
   AVAudioEngine    ────┘     │              │                              │
   (microphone, opt)          └──────────────┘                              ▼
                                                                     ConversationContext
                                                                            │
                              ┌─────────────────────────────────────────────┤
                              │                                             │
                       composer (with optional screenshot)            TriggerEngine
                                              ▲                             │
                              auto-send timer ┘                             ▼
                                              │                       AIProvider
                                              └────────────────►   (Gemini, streaming)
                                                                            │
                                                                            ▼
                                                                     OverlayState ──► SwiftUI overlay
                                                                            │
                                                                            ▼
                                                                     SessionStore (transcript.md + chat.md)
```

Module-by-module breakdown lives in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). Each module is behind a small protocol — swapping in a different LLM, transcriber, or VAD is a matter of conforming to the protocol and registering the implementation in `AppCoordinator`.

## Configuration

Settings persist in `UserDefaults`. The Gemini API key lives in Keychain.

| Setting | Default | Where | Notes |
| --- | --- | --- | --- |
| Gemini API key | — | AI Provider tab | Keychain-backed |
| Gemini model | `gemini-2.0-flash` | AI Provider tab | Flash is the right call for first-token latency |
| Response style | `concise` | General tab | `concise` / `detailed` / `strategic` / `follow-up` |
| Locale | system locale | General tab | `SFSpeechRecognizer` is locale-bound |
| Auto-send to AI | `Off` | General tab | `30 s` / `1 min` / `2 min` / `5 min` |
| Capture microphone | off | Capture tab | When off, only system audio is transcribed |
| Always on top | on | Overlay tab | Window level `.floating` |
| Click-through | off | Overlay tab | Ignores mouse events on the overlay |

## Permissions persist across rebuilds — set up Personal Team signing

By default, Xcode signs the app **ad-hoc** (`CODE_SIGN_IDENTITY = "-"`). Every time you rebuild, the binary's hash changes, and macOS's TCC database treats the new build as a different app — so it forgets your Microphone / Screen Recording grants and asks again, requiring your admin password to re-enable. That gets old fast.

**Fix it once with a free Apple ID Personal Team:**

1. Open Xcode → **Settings → Accounts** → **+** → sign in with your Apple ID. (Free; no paid Developer Program needed.)
2. In the project, select the **WhisperPilot** target → **Signing & Capabilities**.
3. Change **Team** from "None" to your name (Personal Team). Xcode generates a stable certificate.
4. Build once. macOS prompts for permissions one final time. Grant them.
5. From now on, rebuilds reuse the same code signature → TCC remembers your permissions → no more password prompts.

This works because TCC tracks Personal Team signed binaries by stable identity rather than by content hash.

## Privacy

- **Audio is processed in-memory and never written to disk.** Only the resulting transcript is persisted, and only into the active session folder.
- **Transcription runs locally** via Apple's `SFSpeechRecognizer` with on-device recognition where the locale supports it. No audio leaves the machine for transcription.
- **The LLM call is the only thing that leaves your Mac** — and only when the trigger engine fires, the auto-send timer ticks, or you explicitly submit something in the composer. No background polling.
- **Screenshots are captured only when you tick *See my screen*** and are sent inline with that single prompt. They're not cached, not written to disk, not retained.
- **No backend, no telemetry, no signup.** The Gemini API key lives in your Keychain.

## Roadmap

The high points (full list in [`docs/ROADMAP.md`](docs/ROADMAP.md)):

- **WhisperKit transcriber** — drop-in alternative to `SFSpeechRecognizer`, better quality, runs on the Apple Neural Engine.
- **Local LLM provider** — Ollama / `llama.cpp` behind the same `AIProvider` protocol.
- **Speaker diarization** — beyond the system-vs-mic channel split.
- **Per-mode prompts** — coding interview, sales call, customer support each get specialized system prompts.
- **End-of-session summary** — action items, decisions, follow-ups.
- **Realtime translation overlay.**
- **Cross-session memory / RAG.**

## Contributing

We'd like the help. See [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md). Modules are small, protocol-first, and isolated; swapping or extending one rarely touches the rest.

A few areas that especially need eyes:

- The trigger heuristic is hand-rolled. Snapshot tests against real transcripts would catch regressions.
- WhisperKit transcriber.
- Anyone who knows ScreenCaptureKit well enough to make the audio path more robust on multi-display / virtual-output setups.

## License

MIT — see [`LICENSE`](LICENSE).
