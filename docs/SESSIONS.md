# Sessions

Sessions are how Whisper Pilot organizes a single listening period — a meeting, a video, a lecture. Each one is a folder of plain markdown on disk that exists independently of the app: you can browse, grep, share, version-control, or hand-edit them without Whisper Pilot running.

## On-disk layout

```
~/Library/Application Support/com.whisperpilot.app/sessions/
└── <slug>-YYYY-MM-DD-HH-mm/
    ├── transcript.md
    ├── chat.md
    └── metadata.json
```

The folder name is `<slug>-<timestamp>` where the slug is derived from the display name you pick when starting the session (or auto-generated if you skipped the prompt).

### `transcript.md`

Appended live, one block per finalized transcript segment. Each block carries the channel (`ME` / `OTHER`), timestamp, and the recognized text:

```markdown
## OTHER · 14:02:11
Welcome to the call. Do you have a minute to discuss the proposal?

## ME · 14:02:18
Yes, I had a chance to read through it last night.
```

Only **finalized** segments land here — partial hypotheses produced by the speech recognizer are kept in memory and overwritten in place; only the final text is persisted.

### `chat.md`

Appended live, one heading per AI turn (user prompts and assistant responses). The role and timestamp head each block:

```markdown
## You · 14:03:00
What was the timeline they mentioned?

## Assistant · 14:03:01
They mentioned needing the proposal by end of Q3 — September 30.
```

System notes (the contextual messages the overlay shows, e.g. *"Microphone permission was not granted"*) are deliberately **not** persisted — they're UI affordances, not part of the conversation.

### `metadata.json`

Display name + created/last-used timestamps. Not strictly required — if it's missing, the sessions list falls back to deriving information from the folder name and file timestamps.

## Lifecycle

- **Created** when you click *Start new* in the Sessions window. The folder is created lazily on first transcript write, so an empty session doesn't litter disk.
- **Resumed** when you click *Resume* on an existing row. The app reads `transcript.md` and `chat.md` and seeds them into the [ConversationContext](ARCHITECTURE.md) so the next AI prompt has the prior content as context.
- **Deleted** from the Sessions window's overflow menu. The entire folder is moved to the Trash so you can recover from accidents.
- **Exported** from the overlay's `…` menu → *Export transcript…* (⌘E). Writes a copy of the active session's `transcript.md` to a path you pick. The original on-disk file is untouched.

## Resume costs more in tokens

The blue tip in the Sessions window says it explicitly, and it's worth restating here: **resuming a session re-includes its prior transcript and chat in every AI prompt** from that point forward. The longer the prior content, the more tokens each prompt costs. Prefer starting a fresh session unless you actually need the prior context — for a new meeting with a new agenda, fresh is almost always right.

There is no automatic context-pruning when you resume. If you resume a session with 10,000 transcript lines, every prompt will carry all 10,000 lines until you start a new session. This is deliberate: the alternative — silently dropping older content — would produce subtly wrong AI responses without telling you why. Future versions may add a "summarize and forget" affordance.

## Privacy implications

Because sessions are plain markdown:

- **Filesystem-level encryption applies** (FileVault).
- **iCloud Drive doesn't sync them** unless you've configured `~/Library/Application Support` to sync, which is non-default.
- **Spotlight indexes them** by default — they show up in search. If you don't want that, exclude the folder via *System Settings → Siri & Spotlight → Spotlight Privacy*.
- **Time Machine backs them up** with the rest of `~/Library/Application Support`.

If you need stronger guarantees (encrypted-at-rest sessions, ephemeral-mode), [docs/ROADMAP.md](ROADMAP.md) tracks the encrypted persistence proposal — open an issue to push it up the queue.
