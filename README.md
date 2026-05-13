<p align="center">
  <img src="Resources/Branding/whisper-logo-nobg.png" alt="Whisper Pilot" width="160" />
</p>

<h1 align="center">Whisper Pilot</h1>

<p align="center">
  <strong>Ambient, local-first AI co-pilot for live conversations on your Mac.</strong><br>
  Listens, transcribes on-device, and lets you ask an AI about what's happening — without alt-tabbing.
</p>

<p align="center">
  <a href="https://github.com/vertocode/whisper-pilot/releases"><img alt="Status" src="https://img.shields.io/badge/status-alpha-orange"></a>
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/license-MIT-blue"></a>
  <a href="#requirements"><img alt="macOS" src="https://img.shields.io/badge/macOS-14%2B-lightgrey"></a>
</p>

---

Whisper Pilot listens to anything your Mac can hear — meetings, podcasts, tutorials, your own voice — transcribes it on-device, and streams answers from your favorite LLM into a translucent floating overlay. Bring your own key. No backend. No telemetry. No signup.

**Built for:** live meetings (Zoom, Meet, Teams, Slack, Discord), tutorials and lectures, pair programming with screen context, live translation, and anything else you might want to ask a question *about right now*.

## Install

> **Alpha note:** releases are unsigned for now, so macOS Gatekeeper will warn on first launch — see the [Direct download](#direct-download) section for the one-time unblock. Prefer to build it yourself? See [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md#project-setup).

### Homebrew

```sh
brew install --cask vertocode/whisper-pilot/whisper-pilot
```

Update with `brew upgrade --cask whisper-pilot`. Uninstall with `brew uninstall --cask whisper-pilot`. Pass `--zap` to also clear preferences (session transcripts are deliberately kept).

### Direct download

Grab the latest `.dmg` from the [Releases page](https://github.com/vertocode/whisper-pilot/releases) and drag `WhisperPilot.app` into `/Applications`.

> macOS Gatekeeper will warn until releases are notarized. To bypass: right-click the app → **Open** → **Open**. Or in Terminal: `xattr -dr com.apple.quarantine /Applications/WhisperPilot.app`.

### First run

1. Launch — the Sessions window opens. Click **Start new** to enter the overlay.
2. Open Settings from the overlay's `…` menu → **AI Provider** tab → paste your [Gemini API key](https://aistudio.google.com/app/apikey). Stored in Keychain.
3. Click **▶** in the overlay. macOS will prompt for **Screen Recording** permission — grant it. (Microphone is requested separately and only if you enable *Capture microphone*.)

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon recommended (Intel works; transcription is slower)
- A Gemini API key from [aistudio.google.com](https://aistudio.google.com/app/apikey)

## How you use it

The overlay is always available once you've picked a session.

- **Detected questions.** When someone asks *you* a question in a meeting, the trigger engine notices and streams a suggested answer into the AI lane automatically.
- **Composer.** Type any question in the box at the bottom. ⌘⏎ to send. Tick *See my screen* to also include a screenshot.
- **Auto-send.** Optionally set an interval (30s–5m) and the assistant proactively summarizes the recent conversation on every tick. Off by default.
- **Pause AI.** Sparkles button in the header. Listening + transcribing keep running; only the AI is silenced.

## Privacy

- **Audio never leaves your device.** Capture and transcription are entirely local — `SFSpeechRecognizer` with on-device recognition where the locale supports it.
- **The LLM is the only thing that talks to the network**, and only when *you* trigger it (auto-send tick, detected question, or composer submit). No background polling.
- **Your API key lives in the macOS Keychain.** Never written to disk in plaintext.
- **Screenshots are sent only when you tick *See my screen*** — never cached, never persisted.

## Documentation

| | |
| --- | --- |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Module-by-module breakdown, data flow, protocols |
| [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md) | Every setting and what it controls |
| [`docs/SESSIONS.md`](docs/SESSIONS.md) | On-disk session format and resume semantics |
| [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md) | Build from source, conventions, areas that need help |
| [`docs/RELEASE.md`](docs/RELEASE.md) | DMG signing, notarization, Homebrew tap workflow |
| [`docs/ROADMAP.md`](docs/ROADMAP.md) | What's next: WhisperKit, Ollama, diarization, modes, RAG |

## Contributing

The codebase is small, protocol-first, and intentionally non-magical — most contributions fit inside a single module. Start with [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), then [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md). High-value areas right now: WhisperKit transcriber, Ollama provider, snapshot tests for the trigger heuristics, real app icon.

## License

MIT — see [`LICENSE`](LICENSE).
