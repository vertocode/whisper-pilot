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
**Other** [14:02:11] Welcome to the call. Do you have a minute to discuss the proposal?

**Me** [14:02:18] Yes, I had a chance to read through it last night.
```

Only **finalized** segments land here — partial hypotheses produced by the speech recognizer are kept in memory and overwritten in place; only the final text is persisted.

### `chat.md`

Appended live, one heading per AI turn (user prompts and assistant responses). The role and timestamp head each block:

```markdown
## You [14:03:00]

What was the timeline they mentioned?

## Assistant [14:03:01]

They mentioned needing the proposal by end of Q3 — September 30.
```

Newer sessions may include an invisible HTML comment beneath a turn heading to preserve
its UI origin (for example, an auto-detected question). Older files without this metadata
remain fully supported, and the comment does not appear in rendered Markdown.

An AI reply that was cancelled, failed part-way or was cut off (for example by the token limit) is still saved with what you saw, followed by a final `(incomplete)` line, so a resumed session does not mistake it for a finished answer.

System notes (the contextual messages the overlay shows, e.g. *"Microphone permission was not granted"*) are deliberately **not** persisted — they're UI affordances, not part of the conversation.

### `metadata.json`

Display name + created/last-used timestamps. Not strictly required — if it's missing, the sessions list falls back to deriving information from the folder name and file timestamps.

## Lifecycle

- **Created** when you click *Start new* in the Sessions window. Transcript, chat, and metadata files are seeded immediately so the folder is ready to inspect or resume.
- **Resumed** when you click *Resume* on an existing row. The app reads `transcript.md` and `chat.md` and seeds them into the [ConversationContext](ARCHITECTURE.md) so the next AI prompt has the prior content as context.
- **Deleted** from the Sessions window's overflow menu. The entire folder is moved to the Trash so you can recover from accidents.
- **Exported** from the overlay's `…` menu → *Export transcript…* (⌘E). Writes a copy of the active session's `transcript.md` to a path you pick. The original on-disk file is untouched.

## Projects

Projects group related sessions, like a recurring meeting. The Sessions window has a sidebar with a search box, your projects as expandable folders, and the sessions that are not in one.

- **Create, rename, delete** from the sidebar (`+` next to *Projects*, or right-click a folder). Deleting a project never deletes its sessions: they move back to the ungrouped list. The dialog also offers to move them to the Trash, behind a second confirmation.
- **Move sessions** by dragging them onto a folder (or onto the *Sessions* list to take them out), or with *Move to project* in a session's menu.
- **Start a session inside a project** from the project page or the folder's right-click menu. It is created already assigned.
- **Instructions and files** are edited on the project page (text, markdown, html, json, txt, pdf). They are sent with every AI prompt in that project's sessions.
- **Earlier sessions as context** (on by default, per project): the prompt gets short summaries of the project's earlier sessions, newest first, within a 12,000-character budget. A session with no summary yet contributes the end of its transcript.
- **Search** matches titles, project names, transcripts and summaries, across all projects.

### Auto-title and summary

When you stop a session, the app asks the active AI model for a short title and a recap of the transcript. The title is only applied to sessions that still have the placeholder name and were never named by you; a name you typed, or a rename made while the AI was working, always wins. The recap is saved as `summary.json` in the session folder. If there is no AI key, too little was said, or the call fails, nothing changes.

### Storage

- `metadata.json` gains two optional fields: `projectID` and `titleSource` (`user` or `auto`). Older files without them load as ungrouped sessions with no title source, and are not rewritten until you change something about that session.
- `<App Support>/<bundle>/projects.json` holds the projects (`schemaVersion` 1), next to `global-context.json`.
- On first launch with this version, every `metadata.json` is copied to `<App Support>/<bundle>/backups/pre-projects/` and `storage-version.json` is written so the copy happens once.

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
