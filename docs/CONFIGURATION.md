# Configuration

Every setting Whisper Pilot exposes, where it lives, and what it controls.

## Where settings persist

| Storage | What goes here |
| --- | --- |
| `UserDefaults` (`~/Library/Preferences/com.whisperpilot.app.plist`) | All non-secret preferences below |
| macOS **Keychain** (`com.whisperpilot.app`) | Gemini API key — never written to disk in plaintext |
| `~/Library/Application Support/com.whisperpilot.app/sessions/` | Per-session transcripts and chat history (see [SESSIONS.md](SESSIONS.md)) |

## Settings reference

Every setting below is reachable from the overlay's `…` menu → **Settings**.

### AI Provider tab

| Setting | Default | Notes |
| --- | --- | --- |
| **Gemini API key** | — | Stored in Keychain. Get one at [aistudio.google.com](https://aistudio.google.com/app/apikey). The app works without one for transcription-only mode. |
| **Model** | `gemini-2.0-flash` | `flash` is the right call for first-token latency. `flash-lite` is cheaper. `2.5-pro` is slower but more capable. |

### General tab

| Setting | Default | Notes |
| --- | --- | --- |
| **Response style** | `concise` | One of `concise` / `detailed` / `strategic` / `follow-up`. Tunes the system prompt. |
| **Locale** | system locale | `SFSpeechRecognizer` is locale-bound — match the language being spoken. |
| **Auto-send to AI** | `Off` | `Off` / `30 s` / `1 min` / `2 min` / `5 min`. When on, the assistant proactively summarizes recent transcript on every tick. Skipped if no new transcripts since the last send. |
| **Transcript line break** | `Auto` | Controls when a transcript line is finalized into its own row. `Auto` trusts the speech recognizer; `Quick`/`Normal`/`Relaxed`/`Patient`/`Minute` force line breaks after fixed pause durations. |

### Devices tab

| Setting | Default | Notes |
| --- | --- | --- |
| **Microphone input device** | System default | Picks the Core Audio device used when *Capture microphone* is on. Takes effect on the next ▶ Play. |
| **Active output (display only)** | — | What macOS will mix system audio from. Change it in *System Settings → Sound → Output* — Whisper Pilot can't set this for you, but it tells you what you've selected. Some Bluetooth codecs and virtual aggregate devices bypass the mixdown; use the Audio Test diagnostic to verify. |

### Capture tab

| Setting | Default | Notes |
| --- | --- | --- |
| **Capture microphone** | Off | When on, your own voice goes into the transcript as a separate channel attributed to "ME". When off, only system audio (attributed to "OTHER") is transcribed. |

### Overlay tab

| Setting | Default | Notes |
| --- | --- | --- |
| **Always on top** | On | Sets window level `.floating`. Keeps the overlay above your meeting window without alt-tabbing. |
| **Click-through** | Off | Ignores mouse events on the overlay so clicks pass through to whatever's behind it. Useful when you only want the overlay to be readable, not interactive. |

## Resetting everything

```sh
defaults delete com.whisperpilot.app                                 # preferences
security delete-generic-password -a "gemini" -s "com.whisperpilot.app"  # Keychain key
rm -rf ~/Library/Application\ Support/com.whisperpilot.app/sessions   # session data
```

`brew uninstall --cask --zap whisper-pilot` does the first two automatically but leaves session data alone — that's deliberate, since sessions are user data and you probably don't want them wiped silently on an uninstall.
